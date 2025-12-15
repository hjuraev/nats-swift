// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Logging
import Synchronization

/// Main NATS client actor
public actor NatsClient {
    // MARK: - Properties

    private let options: NatsClientOptions
    private var stateMachine = ConnectionStateMachine()
    private let subscriptionManager = SubscriptionManager()
    private var pendingRequests: [String: CheckedContinuation<NatsMessage, any Error>] = [:]

    // NIO components
    private var eventLoopGroup: EventLoopGroup?
    private var channel: Channel?
    private var connectionHandler: ConnectionHandler?

    // Counters using Swift 6 Atomics
    private let _messagesSent = Atomic<UInt64>(0)
    private let _messagesReceived = Atomic<UInt64>(0)

    // Inbox for request-reply
    private var inboxSubscription: Subscription?
    private var inboxPrefix: String

    // Reconnection state
    private var reconnectionState: ReconnectionState

    // Logger
    private let logger: Logger

    // Connection ready continuation (for waiting on handshake)
    private var connectContinuation: CheckedContinuation<Void, any Error>?

    // Track if TLS is being used for current connection
    private var usingTLS: Bool = false

    // MARK: - Initialization

    /// Create a new NATS client with default options
    public init() {
        self.options = NatsClientOptions()
        self.logger = options.logger
        self.inboxPrefix = options.inboxPrefix
        self.reconnectionState = ReconnectionState(policy: options.reconnect)
    }

    /// Create a new NATS client with configuration closure
    public init(_ configure: (inout NatsClientOptions) -> Void) {
        var opts = NatsClientOptions()
        configure(&opts)
        self.options = opts
        self.logger = opts.logger
        self.inboxPrefix = opts.inboxPrefix
        self.reconnectionState = ReconnectionState(policy: opts.reconnect)
    }

    /// Create a new NATS client with options
    public init(options: NatsClientOptions) {
        self.options = options
        self.logger = options.logger
        self.inboxPrefix = options.inboxPrefix
        self.reconnectionState = ReconnectionState(policy: options.reconnect)
    }

    // MARK: - Connection Lifecycle

    /// Connect to the NATS server
    public func connect() async throws(ConnectionError) {
        guard stateMachine.state == .disconnected || stateMachine.state == .closed else {
            logger.warning("Already connected or connecting")
            return
        }

        _ = stateMachine.transition(on: .connect)
        logger.info("Connecting to NATS servers: \(options.servers)")

        do {
            try await establishConnection()

            // Wait for the handshake to complete (INFO received, CONNECT sent)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.connectContinuation = continuation
            }
        } catch let error as ConnectionError {
            connectContinuation = nil
            _ = stateMachine.transition(on: .disconnected(error))
            throw error
        } catch {
            connectContinuation = nil
            let connError = ConnectionError.io(error.localizedDescription)
            _ = stateMachine.transition(on: .disconnected(connError))
            throw connError
        }
    }

    /// Close the connection
    public func close() async {
        logger.info("Closing NATS connection")
        _ = stateMachine.transition(on: .close)

        // Finish all subscriptions
        await subscriptionManager.finishAll()

        // Cancel pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: ConnectionError.closed)
        }
        pendingRequests.removeAll()

        // Close channel
        if let channel = channel {
            try? await channel.close()
        }
        channel = nil
        connectionHandler = nil

        // Shutdown event loop group
        if let group = eventLoopGroup {
            try? await group.shutdownGracefully()
        }
        eventLoopGroup = nil
    }

    /// Drain subscriptions and close gracefully
    public func drain() async throws(ConnectionError) {
        guard stateMachine.state.isActive else {
            throw .closed
        }

        logger.info("Draining NATS connection")
        _ = stateMachine.transition(on: .drain)

        // Wait for pending messages with timeout
        try? await Task.sleep(for: options.drainTimeout)

        await close()
    }

    // MARK: - Publishing

    /// Publish a message to a subject
    public func publish(
        _ subject: String,
        payload: Data = Data(),
        headers: NatsHeaders? = nil
    ) async throws(ProtocolError) {
        try Subject.validateForPublish(subject)

        guard stateMachine.state.canAcceptOperations else {
            throw .serverError("Not connected")
        }

        let buffer = payload.toByteBuffer()
        do {
            try await write(.publish(subject: subject, reply: nil, headers: headers, payload: buffer))
        } catch {
            throw .serverError("Write failed: \(error)")
        }
        _messagesSent.wrappingAdd(1, ordering: .relaxed)
    }

    /// Publish a message with a reply subject
    public func publish(
        _ subject: String,
        payload: Data,
        reply: String
    ) async throws(ProtocolError) {
        try Subject.validateForPublish(subject)
        try Subject.validateForPublish(reply)

        guard stateMachine.state.canAcceptOperations else {
            throw .serverError("Not connected")
        }

        let buffer = payload.toByteBuffer()
        do {
            try await write(.publish(subject: subject, reply: reply, headers: nil, payload: buffer))
        } catch {
            throw .serverError("Write failed: \(error)")
        }
        _messagesSent.wrappingAdd(1, ordering: .relaxed)
    }

    // MARK: - Request-Reply

    /// Send a request and wait for a response
    public func request(
        _ subject: String,
        payload: Data = Data(),
        timeout: Duration? = nil
    ) async throws -> NatsMessage {
        try Subject.validateForPublish(subject)

        guard stateMachine.state.canAcceptOperations else {
            throw ConnectionError.closed
        }

        // Ensure inbox subscription is set up
        try await ensureInboxSubscription()

        let replySubject = Subject.newInbox(prefix: inboxPrefix)
        let effectiveTimeout = timeout ?? options.requestTimeout

        return try await withCheckedThrowingContinuation { continuation in
            Task {
                // Store continuation
                await self.storePendingRequest(replySubject: replySubject, continuation: continuation)

                // Publish request
                let buffer = payload.toByteBuffer()
                do {
                    try await self.write(.publish(subject: subject, reply: replySubject, headers: nil, payload: buffer))
                    self._messagesSent.wrappingAdd(1, ordering: .relaxed)
                } catch {
                    await self.removePendingRequest(replySubject: replySubject)
                    continuation.resume(throwing: error)
                    return
                }

                // Set up timeout
                Task {
                    try? await Task.sleep(for: effectiveTimeout)
                    if let cont = await self.removePendingRequest(replySubject: replySubject) {
                        cont.resume(throwing: NatsError.timeout(operation: "request", after: effectiveTimeout))
                    }
                }
            }
        }
    }

    // MARK: - Subscriptions

    /// Subscribe to a subject
    public func subscribe(
        _ subject: String,
        queue: String? = nil
    ) async throws(ProtocolError) -> Subscription {
        try Subject.validateForSubscribe(subject)

        if let queue = queue {
            guard !queue.isEmpty && !queue.contains(" ") else {
                throw .invalidQueueGroup(queue)
            }
        }

        guard stateMachine.state.canAcceptOperations else {
            throw .serverError("Not connected")
        }

        let sid = await subscriptionManager.generateSid()

        let (stream, continuation) = AsyncStream<NatsMessage>.makeStream()

        await subscriptionManager.register(
            sid: sid,
            subject: subject,
            queueGroup: queue,
            continuation: continuation
        )

        // Send SUB to server
        do {
            try await write(.subscribe(sid: sid, subject: subject, queue: queue))
        } catch {
            await subscriptionManager.unregister(sid: sid)
            throw .serverError("Subscribe failed: \(error)")
        }

        return Subscription(
            subject: subject,
            queueGroup: queue,
            sid: sid,
            stream: stream,
            unsubscribe: { [weak self] in
                await self?.unsubscribe(sid: sid)
            },
            autoUnsubscribe: { [weak self] max in
                await self?.autoUnsubscribe(sid: sid, max: max)
            }
        )
    }

    private func unsubscribe(sid: String) async {
        // First send UNSUB to server to stop message delivery
        try? await write(.unsubscribe(sid: sid, max: nil))
        // Then unregister locally (subscription enters draining state for in-flight messages)
        await subscriptionManager.unregister(sid: sid)
    }

    private func autoUnsubscribe(sid: String, max: Int) async {
        await subscriptionManager.setAutoUnsubscribe(sid: sid, max: max)
        try? await write(.unsubscribe(sid: sid, max: max))
    }

    // MARK: - Status

    /// Current connection state
    public var state: ConnectionState {
        stateMachine.state
    }

    /// Whether the client is connected
    public var isConnected: Bool {
        stateMachine.state.isActive
    }

    /// Server information (if connected)
    public var serverInfo: ServerInfo? {
        stateMachine.state.serverInfo
    }

    /// Client statistics
    nonisolated public var stats: ClientStats {
        ClientStats(
            messagesSent: _messagesSent.load(ordering: .relaxed),
            messagesReceived: _messagesReceived.load(ordering: .relaxed)
        )
    }

    // MARK: - Private Methods

    private func establishConnection() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        guard let serverURL = options.servers.first else {
            throw ConnectionError.noServersAvailable
        }

        let host = serverURL.host ?? "localhost"
        let port = serverURL.port ?? 4222

        // Track if TLS is requested (will be upgraded after INFO)
        // tls:// scheme or explicit tls.enabled means we want TLS
        self.usingTLS = false  // Will be set to true after TLS upgrade

        let handler = ConnectionHandler(
            logger: logger,
            maxPingsOut: options.maxPingsOut,
            onMessage: { [weak self] op in
                Task { await self?.handleServerOp(op) }
            },
            onOpen: { [weak self] in
                Task { await self?.handleConnectionOpen() }
            },
            onClose: { [weak self] error in
                Task { await self?.handleConnectionClose(error: error) }
            }
        )
        self.connectionHandler = handler

        // NATS uses TLS upgrade protocol - connect via TCP first, then upgrade after INFO
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    MessageToByteHandler(ProtocolEncoder()),
                    ByteToMessageHandler(ProtocolDecoder()),
                    handler
                ])
            }

        do {
            let channel = try await bootstrap.connect(host: host, port: port).get()
            self.channel = channel
            logger.info("TCP connection established to \(host):\(port)")
        } catch {
            throw ConnectionError.connectionRefused(host: host, port: port)
        }
    }

    private func handleServerOp(_ op: ServerOp) async {
        switch op {
        case .info(let serverInfo):
            await handleInfo(serverInfo)

        case .msg(let subject, let sid, let reply, let payload):
            await handleMessage(subject: subject, sid: sid, reply: reply, headers: nil, payload: payload)

        case .hmsg(let subject, let sid, let reply, let headers, let payload):
            await handleMessage(subject: subject, sid: sid, reply: reply, headers: headers, payload: payload)

        case .ping:
            // Handled by ConnectionHandler
            break

        case .pong:
            // Handled by ConnectionHandler
            break

        case .ok:
            logger.trace("Received +OK")

        case .err(let message):
            logger.error("Server error: \(message)")
        }
    }

    private func handleInfo(_ info: ServerInfo) async {
        logger.info("Received server info: \(info.serverName) v\(info.version)")

        // Check if TLS is requested via URL scheme or explicit config
        let serverURL = options.servers.first
        let tlsScheme = serverURL?.scheme == "tls"
        let wantsTLS = tlsScheme || options.tls.enabled || (info.tlsRequired == true)

        // Check for TLS requirement - fail if server requires TLS but we don't want it
        if info.tlsRequired == true && !wantsTLS {
            logger.error("Server requires TLS but client is not configured for it")
            let error = ConnectionError.tlsRequired
            connectContinuation?.resume(throwing: error)
            connectContinuation = nil
            await close()
            return
        }

        // Upgrade to TLS if needed (NATS protocol: upgrade after INFO)
        if wantsTLS && !usingTLS {
            do {
                try await upgradeToTLS()
                usingTLS = true
                logger.info("TLS upgrade successful")
            } catch {
                logger.error("TLS upgrade failed: \(error)")
                connectContinuation?.resume(throwing: ConnectionError.tlsHandshakeFailed(reason: error.localizedDescription))
                connectContinuation = nil
                await close()
                return
            }
        }

        // Send CONNECT
        let connectInfo = buildConnectInfo(serverInfo: info)
        do {
            try await write(.connect(connectInfo))
            _ = stateMachine.transition(on: .connected(info))
            logger.info("Connected to NATS server")

            // Start ping timer
            if let handler = connectionHandler {
                let interval = TimeAmount.nanoseconds(Int64(options.pingInterval.components.seconds * 1_000_000_000))
                handler.startPingTimer(interval: interval)
            }

            // Resume connect continuation - connection is ready
            connectContinuation?.resume(returning: ())
            connectContinuation = nil
        } catch {
            logger.error("Failed to send CONNECT: \(error)")
            connectContinuation?.resume(throwing: ConnectionError.io(error.localizedDescription))
            connectContinuation = nil
        }
    }

    private func upgradeToTLS() async throws {
        guard let channel = channel else {
            throw ConnectionError.closed
        }

        // Create TLS configuration
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = options.tls.certificateVerification
        tlsConfig.minimumTLSVersion = options.tls.minimumTLSVersion
        tlsConfig.trustRoots = options.tls.trustRoots

        if !options.tls.certificateChain.isEmpty {
            tlsConfig.certificateChain = options.tls.certificateChain
        }
        if let privateKey = options.tls.privateKey {
            tlsConfig.privateKey = privateKey
        }

        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        let serverURL = options.servers.first
        let hostname = options.tls.serverHostname ?? serverURL?.host ?? "localhost"

        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: hostname)

        // Add TLS handler at the front of the pipeline (before protocol encoder/decoder)
        try await channel.pipeline.addHandler(sslHandler, position: .first).get()

        logger.debug("TLS handler added to pipeline")
    }

    private func handleMessage(
        subject: String,
        sid: String,
        reply: String?,
        headers: NatsHeaders?,
        payload: ByteBuffer
    ) async {
        _messagesReceived.wrappingAdd(1, ordering: .relaxed)

        let message = NatsMessage(
            subject: subject,
            replyTo: reply,
            headers: headers,
            payload: payload.getData() ?? Data(),
            sid: sid
        )

        // Check if this is a response to a pending request
        if subject.hasPrefix(inboxPrefix), let continuation = pendingRequests.removeValue(forKey: subject) {
            // Check for no responders
            if let headers = headers, headers.isNoResponders {
                continuation.resume(throwing: ProtocolError.noResponders(subject: subject))
            } else {
                continuation.resume(returning: message)
            }
            return
        }

        // Deliver to subscription
        let delivered = await subscriptionManager.deliver(sid: sid, message: message)
        if !delivered {
            logger.warning("Received message for unknown subscription: \(sid)")
        }
    }

    private func handleConnectionOpen() async {
        logger.trace("Connection opened")
    }

    private func handleConnectionClose(error: Error?) async {
        logger.info("Connection closed: \(error?.localizedDescription ?? "no error")")

        // If we're still waiting on connect, fail the continuation
        if let continuation = connectContinuation {
            let closeError = error ?? ConnectionError.closed
            continuation.resume(throwing: closeError)
            connectContinuation = nil
        }

        let wasConnected = stateMachine.state.isActive
        _ = stateMachine.transition(on: .disconnected(error))

        if wasConnected && options.reconnect.enabled {
            await attemptReconnection()
        }
    }

    private func attemptReconnection() async {
        await reconnectionState.startReconnecting()

        while await reconnectionState.shouldContinue() {
            let delay = await reconnectionState.nextDelay()
            logger.info("Attempting reconnection in \(delay)")

            try? await Task.sleep(for: delay)

            do {
                try await establishConnection()
                await resubscribeAll()
                await reconnectionState.reset()
                logger.info("Reconnected successfully")
                return
            } catch {
                await reconnectionState.recordAttempt(error: error)
                logger.warning("Reconnection attempt failed: \(error)")
            }
        }

        logger.error("Max reconnection attempts exceeded")
        await close()
    }

    private func resubscribeAll() async {
        let subs = await subscriptionManager.getAllSubscriptions()
        for (sid, subject, queue) in subs {
            try? await write(.subscribe(sid: sid, subject: subject, queue: queue))
        }
    }

    private func buildConnectInfo(serverInfo: ServerInfo) -> ConnectInfo {
        var user: String?
        var pass: String?
        var token: String?
        var jwt: String?
        let nkey: String? = nil
        let sig: String? = nil

        switch options.auth {
        case .none:
            break
        case .token(let t):
            token = t
        case .userPass(let u, let p):
            user = u
            pass = p
        case .nkey(let seed):
            // TODO: Implement NKey signing
            _ = seed
        case .credentials(let url):
            // TODO: Load credentials from file
            _ = url
        case .jwt(let j, let seed):
            jwt = j
            // TODO: Sign nonce with seed
            _ = seed
        }

        return ConnectInfo(
            verbose: options.verbose,
            pedantic: options.pedantic,
            tlsRequired: usingTLS,
            authToken: token,
            user: user,
            pass: pass,
            name: options.name,
            protocol: 1,  // Protocol 1 required for headers/JetStream
            echo: options.echo,
            headers: true,
            noResponders: true,
            jwt: jwt,
            nkey: nkey,
            sig: sig
        )
    }

    private func ensureInboxSubscription() async throws {
        if inboxSubscription != nil { return }

        let inboxSubject = "\(inboxPrefix).>"
        inboxSubscription = try await subscribe(inboxSubject)

        Task {
            guard let sub = inboxSubscription else { return }
            for await message in sub {
                // Messages are handled in handleMessage via the subscription manager
                _ = message
            }
        }
    }

    private func storePendingRequest(
        replySubject: String,
        continuation: CheckedContinuation<NatsMessage, any Error>
    ) async {
        pendingRequests[replySubject] = continuation
    }

    @discardableResult
    private func removePendingRequest(
        replySubject: String
    ) async -> CheckedContinuation<NatsMessage, any Error>? {
        pendingRequests.removeValue(forKey: replySubject)
    }

    private func write(_ op: ClientOp) async throws {
        guard let channel = channel else {
            throw ConnectionError.closed
        }
        try await channel.writeAndFlush(op)
    }
}

// MARK: - Client Statistics

public struct ClientStats: Sendable {
    public let messagesSent: UInt64
    public let messagesReceived: UInt64
}
