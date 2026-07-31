// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
@preconcurrency import NIOCore
import NIOPosix
@preconcurrency import NIOSSL
import Logging
import Synchronization

/// Main NATS client actor
public actor NatsClient {
    // MARK: - Properties

    private let options: NatsClientOptions
    private var stateMachine = ConnectionStateMachine()
    private let subscriptionManager = SubscriptionManager()

    /// Pending request tracking for request-reply pattern
    private struct PendingRequest {
        let continuation: CheckedContinuation<NatsMessage, any Error>
        let requestSubject: String
    }

    private var pendingRequests: [String: PendingRequest] = [:]

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
    private var reconnectionTask: Task<Void, Never>?

    // Logger
    private let logger: Logger

    // Connection ready continuation (for waiting on handshake)
    private var connectContinuation: CheckedContinuation<Void, any Error>?

    // Whether a connect/reconnect attempt is currently waiting on a handshake.
    // Gates `settleHandshake` so a close event arriving outside an attempt is
    // not parked and mis-delivered to some later connect().
    private var handshakeInFlight: Bool = false

    // Handshake outcome that arrived before its waiter did. The INFO handler
    // runs on its own task, so it can in principle reach the resume point
    // before connect() has stored its continuation; parking the result here
    // means the waiter picks it up instead of suspending on a continuation
    // nothing will ever resume.
    private var pendingHandshakeResult: Result<Void, any Error>?

    // Track if we're waiting for connection confirmation (to catch auth errors)
    private var awaitingConnectionConfirmation: Bool = false

    // Track if TLS is being used for current connection
    private var usingTLS: Bool = false

    // Monotonically increasing connection generation. Bumped on every
    // (re)connection attempt so that callbacks from a superseded channel
    // (a late INFO or channelInactive from a connection we are tearing down)
    // can be identified and ignored instead of corrupting the live one.
    private var connectionGeneration: UInt64 = 0

    // MARK: - Initialization

    /// Create a new NATS client with default options
    public init() {
        self.options = NatsClientOptions()
        self.logger = options.logger
        self.inboxPrefix = "\(options.inboxPrefix).\(Subject.randomToken())"
        self.reconnectionState = ReconnectionState(policy: options.reconnect)
    }

    /// Create a new NATS client with configuration closure
    public init(_ configure: (inout NatsClientOptions) -> Void) {
        var opts = NatsClientOptions()
        configure(&opts)
        self.options = opts
        self.logger = opts.logger
        self.inboxPrefix = "\(opts.inboxPrefix).\(Subject.randomToken())"
        self.reconnectionState = ReconnectionState(policy: opts.reconnect)
    }

    /// Create a new NATS client with options
    public init(options: NatsClientOptions) {
        self.options = options
        self.logger = options.logger
        self.inboxPrefix = "\(options.inboxPrefix).\(Subject.randomToken())"
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
        logger.info("Connecting to NATS servers: \(options.servers.map { $0.sanitizedDescription })")

        beginHandshake()
        do {
            try await establishConnection()

            // Wait for the handshake to complete (INFO received, CONNECT sent)
            try await waitForHandshake()
        } catch let error as ConnectionError {
            endHandshake()
            _ = stateMachine.transition(on: .disconnected(error))
            throw error
        } catch {
            endHandshake()
            let connError = ConnectionError.io(error.localizedDescription)
            _ = stateMachine.transition(on: .disconnected(connError))
            throw connError
        }
    }

    // MARK: - Handshake Handoff

    /// Mark the start of a connect/reconnect attempt, discarding any outcome
    /// left parked by a previous one.
    private func beginHandshake() {
        handshakeInFlight = true
        pendingHandshakeResult = nil
        connectContinuation = nil
    }

    /// Mark the attempt finished and drop any state it left behind.
    private func endHandshake() {
        handshakeInFlight = false
        pendingHandshakeResult = nil
        connectContinuation = nil
    }

    /// Deliver a handshake outcome to whoever is waiting in `waitForHandshake()`.
    ///
    /// Safe to call before the waiter has stored its continuation: the result
    /// is parked and collected when the waiter arrives. Every handshake
    /// success/failure path must funnel through here rather than poking
    /// `connectContinuation` directly, or an outcome that outruns its waiter
    /// resumes nobody and the connect hangs on a healthy socket.
    private func settleHandshake(_ result: Result<Void, any Error>) {
        guard handshakeInFlight else { return }

        if let continuation = connectContinuation {
            connectContinuation = nil
            pendingHandshakeResult = nil
            handshakeInFlight = false
            continuation.resume(with: result)
        } else {
            pendingHandshakeResult = result
        }
    }

    /// Suspend until the handshake settles, honouring cancellation.
    ///
    /// The bare `withCheckedThrowingContinuation` this replaces was not
    /// cancellation-aware: cancelling a connect requested cancellation and then
    /// waited forever, because nothing resumed the continuation. Callers that
    /// race this against a deadline (Nexus boot does) were left holding a task
    /// that could never finish.
    private func waitForHandshake() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Re-check under the same actor step that stores the
                // continuation, so an outcome cannot slip in between.
                if let parked = pendingHandshakeResult {
                    pendingHandshakeResult = nil
                    handshakeInFlight = false
                    continuation.resume(with: parked)
                } else {
                    connectContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.abandonHandshake() }
        }
    }

    /// Fail an in-flight handshake wait and tear down the half-open attempt.
    ///
    /// Without the teardown a cancelled connect would leave a socket, an
    /// event-loop group and a reconnect loop running on behalf of a caller that
    /// has already given up.
    private func abandonHandshake() async {
        guard handshakeInFlight else { return }

        let continuation = connectContinuation
        endHandshake()
        continuation?.resume(throwing: CancellationError())

        logger.info("Connect cancelled; tearing down the in-flight attempt")
        await close()
    }

    /// Close the connection
    public func close() async {
        logger.info("Closing NATS connection")

        // Cancel any ongoing reconnection first
        reconnectionTask?.cancel()
        reconnectionTask = nil

        _ = stateMachine.transition(on: .close)

        // Finish all subscriptions
        await subscriptionManager.finishAll()

        // Cancel pending requests
        for (_, continuation) in pendingRequests {
            continuation.continuation.resume(throwing: ConnectionError.closed)
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
    ///
    /// This method:
    /// 1. Stops accepting new publish/subscribe operations
    /// 2. Sends UNSUB for all active subscriptions
    /// 3. Allows a brief window for in-flight messages to be delivered
    /// 4. Closes the connection
    ///
    /// Note: Subscription iterators will receive `nil` after drain completes.
    public func drain() async throws(ConnectionError) {
        guard stateMachine.state.isActive else {
            throw .closed
        }

        logger.info("Draining NATS connection")
        _ = stateMachine.transition(on: .drain)

        // Get all active subscriptions before we start draining
        let activeSubscriptions = await subscriptionManager.getAllSubscriptions()

        // Send UNSUB for all subscriptions to stop receiving new messages from server
        for (sid, _, _, _) in activeSubscriptions {
            try? await write(.unsubscribe(sid: sid, max: nil))
            await subscriptionManager.markDraining(sid: sid)
        }

        // Brief delay to allow in-flight messages to arrive and be delivered
        // This is much shorter than drainTimeout - just enough for network latency
        try? await Task.sleep(for: .milliseconds(500))

        // Now close the connection - this will finish all subscription continuations
        await close()
    }

    // MARK: - Publishing

    /// Publish a message to a subject
    public func publish(
        _ subject: String,
        payload: ByteBuffer = ByteBuffer(),
        headers: NatsHeaders? = nil
    ) async throws(ProtocolError) {
        try Subject.validateForPublish(subject)

        guard stateMachine.state.canAcceptOperations else {
            throw .serverError("Not connected")
        }

        do {
            try await write(.publish(subject: subject, reply: nil, headers: headers, payload: payload))
        } catch {
            throw .serverError("Write failed: \(error)")
        }
        _messagesSent.wrappingAdd(1, ordering: .relaxed)
    }

    /// Publish a message with a reply subject
    public func publish(
        _ subject: String,
        payload: ByteBuffer,
        reply: String,
        headers: NatsHeaders? = nil
    ) async throws(ProtocolError) {
        try Subject.validateForPublish(subject)
        try Subject.validateForPublish(reply)

        guard stateMachine.state.canAcceptOperations else {
            throw .serverError("Not connected")
        }

        do {
            try await write(.publish(subject: subject, reply: reply, headers: headers, payload: payload))
        } catch {
            throw .serverError("Write failed: \(error)")
        }
        _messagesSent.wrappingAdd(1, ordering: .relaxed)
    }

    // MARK: - Request-Reply

    /// Send a request and wait for a response
    public func request(
        _ subject: String,
        payload: ByteBuffer = ByteBuffer(),
        headers: NatsHeaders? = nil,
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
                // Store continuation with original request subject for error reporting
                await self.storePendingRequest(replySubject: replySubject, requestSubject: subject, continuation: continuation)

                // Publish request
                do {
                    try await self.write(.publish(subject: subject, reply: replySubject, headers: headers, payload: payload))
                    self._messagesSent.wrappingAdd(1, ordering: .relaxed)
                } catch {
                    await self.removePendingRequest(replySubject: replySubject)
                    continuation.resume(throwing: error)
                    return
                }

                // Set up timeout
                Task {
                    try? await Task.sleep(for: effectiveTimeout)
                    if let pending = await self.removePendingRequest(replySubject: replySubject) {
                        pending.continuation.resume(throwing: NatsError.timeout(operation: "request", after: effectiveTimeout))
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
        // Prevent creating resources if already closed
        guard stateMachine.state != .closed else {
            throw ConnectionError.closed
        }

        // Bump the generation before touching the old channel: callbacks from
        // the previous channel captured the old generation, so any late event
        // it emits while we tear it down is ignored (see handleConnection*).
        connectionGeneration &+= 1
        let generation = connectionGeneration

        // Close the previous connection's channel so a dropped or
        // failed-handshake socket isn't left dangling on the event loop.
        if let oldChannel = channel {
            try? await oldChannel.close()
            self.channel = nil
        }
        self.connectionHandler = nil

        // Reuse the EventLoopGroup across reconnect attempts — it is only
        // shut down by close(). Creating a fresh group every attempt would
        // leak a group and its backing thread on each reconnect.
        let group: EventLoopGroup
        if let existingGroup = eventLoopGroup {
            group = existingGroup
        } else {
            group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.eventLoopGroup = group
        }

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
                Task { await self?.handleServerOp(op, generation: generation) }
            },
            onOpen: { [weak self] in
                Task { await self?.handleConnectionOpen(generation: generation) }
            },
            onClose: { [weak self] error in
                Task { await self?.handleConnectionClose(error: error, generation: generation) }
            }
        )
        self.connectionHandler = handler

        // NATS uses TLS upgrade protocol - connect via TCP first, then upgrade after INFO
        let protocolLogger = self.logger
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    MessageToByteHandler(ProtocolEncoder(logger: protocolLogger)),
                    ByteToMessageHandler(ProtocolDecoder(logger: protocolLogger)),
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

    private func handleServerOp(_ op: ServerOp, generation: UInt64) async {
        // Drop frames from a superseded connection (e.g. a late INFO from a
        // channel being torn down during reconnect).
        guard generation == connectionGeneration else { return }

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
            // Check if this is an auth error during connection
            if awaitingConnectionConfirmation {
                awaitingConnectionConfirmation = false
                let error: ConnectionError
                if message.lowercased().contains("authorization") || message.lowercased().contains("authentication") {
                    error = .authenticationFailed(reason: message)
                } else {
                    error = .io(message)
                }
                settleHandshake(.failure(error))
            }
        }
    }

    private func handleInfo(_ info: ServerInfo) async {
        logger.info("Received server info: \(info.serverName) v\(info.version)")

        // Async INFO from the server after the initial handshake. NATS pushes
        // these whenever cluster topology changes (peer added/removed, lame
        // duck mode, connect_urls update). The protocol does NOT expect a
        // client response — we must not re-send CONNECT here. Sending a
        // duplicate CONNECT mid-session corrupts connection-scoped server
        // state (subscriptions, no_responders flag, header support) and
        // silently bricks the session even though the TCP socket stays open.
        if case .connected = stateMachine.state {
            handleAsyncServerInfoUpdate(info)
            return
        }

        // Check if TLS is requested via URL scheme or explicit config
        let serverURL = options.servers.first
        let tlsScheme = serverURL?.scheme == "tls"
        let wantsTLS = tlsScheme || options.tls.enabled || (info.tlsRequired == true)

        // Check for TLS requirement - fail if server requires TLS but we don't want it
        if info.tlsRequired == true && !wantsTLS {
            logger.error("Server requires TLS but client is not configured for it")
            let error = ConnectionError.tlsRequired
            settleHandshake(.failure(error))
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
                settleHandshake(.failure(ConnectionError.tlsHandshakeFailed(reason: error.localizedDescription)))
                await close()
                return
            }
        }

        // Send CONNECT
        let connectInfo = buildConnectInfo(serverInfo: info)
        do {
            // Mark that we're waiting for connection confirmation
            // This allows us to catch -ERR responses (auth failures) before confirming
            awaitingConnectionConfirmation = true

            try await write(.connect(connectInfo))

            // Small delay to allow -ERR to arrive before confirming connection
            // This catches auth failures that arrive shortly after CONNECT
            try? await Task.sleep(for: .milliseconds(250))

            // Only proceed if we're still awaiting confirmation (not cancelled by -ERR handler)
            guard awaitingConnectionConfirmation else {
                // Auth or other error occurred - don't complete connection
                return
            }

            awaitingConnectionConfirmation = false
            _ = stateMachine.transition(on: .connected(info))
            logger.info("Connected to NATS server")

            // Start ping timer
            if let handler = connectionHandler {
                let interval = TimeAmount.nanoseconds(Int64(options.pingInterval.components.seconds * 1_000_000_000))
                handler.startPingTimer(interval: interval)
            }

            settleHandshake(.success(()))
        } catch {
            awaitingConnectionConfirmation = false
            logger.error("Failed to send CONNECT: \(error)")
            settleHandshake(.failure(ConnectionError.io(error.localizedDescription)))
        }
    }

    /// Apply an async INFO frame received after the initial handshake.
    /// These carry cluster topology updates and are advisory — no response
    /// is sent on the wire. Future work: feed `info.connectUrls` into the
    /// reconnection server pool so failover can use newly-discovered peers.
    private func handleAsyncServerInfoUpdate(_ info: ServerInfo) {
        if let urls = info.connectUrls, !urls.isEmpty {
            logger.debug("Cluster connect_urls update: \(urls)")
        }
        if info.lameDuckMode == true {
            logger.notice("Server entered lame duck mode: \(info.serverName)")
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
            buffer: payload,
            sid: sid
        )

        // Check if this is a response to a pending request
        if subject.hasPrefix(inboxPrefix + "."), let pending = pendingRequests.removeValue(forKey: subject) {
            // Check for no responders - use the original request subject for clearer error messages
            if let headers = headers, headers.isNoResponders {
                pending.continuation.resume(throwing: ProtocolError.noResponders(subject: pending.requestSubject))
            } else {
                pending.continuation.resume(returning: message)
            }
            return
        }

        // Deliver to subscription
        let delivered = await subscriptionManager.deliver(sid: sid, message: message)
        if !delivered {
            logger.warning("Received message for unknown subscription: \(sid)")
        }
    }

    private func handleConnectionOpen(generation: UInt64) async {
        guard generation == connectionGeneration else { return }
        logger.trace("Connection opened")
    }

    private func handleConnectionClose(error: Error?, generation: UInt64) async {
        // Ignore close events from a superseded connection. Without this,
        // tearing down the old channel during a reconnect would knock the new
        // connection's state back to .disconnected or spawn a rogue reconnect.
        guard generation == connectionGeneration else {
            logger.trace("Ignoring close from stale connection generation \(generation)")
            return
        }

        logger.info("Connection closed: \(error?.localizedDescription ?? "no error")")

        // If we're still waiting on connect, fail the handshake. The
        // in-flight guard inside settleHandshake keeps a close that arrives
        // outside an attempt from being parked for a later connect().
        settleHandshake(.failure(error ?? ConnectionError.closed))

        // Don't attempt reconnection if already closed or closing
        guard stateMachine.state != .closed else {
            return
        }

        let wasConnected = stateMachine.state.isActive
        _ = stateMachine.transition(on: .disconnected(error))

        if wasConnected && options.reconnect.enabled {
            // Store the task so it can be cancelled by close()
            reconnectionTask = Task {
                await attemptReconnection()
            }
        }
    }

    private func attemptReconnection() async {
        await reconnectionState.startReconnecting()

        while await reconnectionState.shouldContinue() {
            // Check if cancelled or closed before each attempt
            guard !Task.isCancelled && stateMachine.state != .closed else {
                logger.debug("Reconnection cancelled or connection closed")
                await reconnectionState.reset()
                return
            }

            let delay = await reconnectionState.nextDelay()
            logger.info("Attempting reconnection in \(delay)")

            do {
                try await Task.sleep(for: delay)
            } catch {
                // Task was cancelled during sleep
                logger.debug("Reconnection sleep cancelled")
                await reconnectionState.reset()
                return
            }

            // Check again after sleep
            guard !Task.isCancelled && stateMachine.state != .closed else {
                logger.debug("Reconnection cancelled or connection closed")
                await reconnectionState.reset()
                return
            }

            do {
                // Move the state machine into .connecting so the handshake
                // has a valid path to .connected. Without this the state is
                // still .disconnected, which has no transition to .connected,
                // leaving the client permanently stuck after a reconnect.
                _ = stateMachine.transition(on: .connect)

                beginHandshake()
                try await establishConnection()

                // Wait for the NATS handshake to complete (INFO received,
                // CONNECT sent and confirmed) before resubscribing.
                // establishConnection() only completes the TCP connect — SUB
                // frames sent before CONNECT race the handshake and are
                // dropped by the server. handleInfo() settles this wait once
                // the session is fully connected.
                try await waitForHandshake()

                await resubscribeAll()
                await reconnectionState.reset()
                logger.info("Reconnected successfully")
                return
            } catch {
                endHandshake()
                await reconnectionState.recordAttempt(error: error)
                logger.warning("Reconnection attempt failed: \(error)")
            }
        }

        logger.error("Max reconnection attempts exceeded")
        await close()
    }

    /// Re-send SUB for every active subscription after a reconnect.
    ///
    /// Must only be called once the NATS handshake has completed — SUB frames
    /// sent before CONNECT are discarded by the server, which is what would
    /// otherwise make subscriptions silently stop receiving messages after a
    /// reconnect.
    private func resubscribeAll() async {
        let subs = await subscriptionManager.getAllSubscriptions()
        logger.debug("Resubscribing to \(subs.count) subject(s) after reconnect")
        for (sid, subject, queue, remainingMax) in subs {
            do {
                try await write(.subscribe(sid: sid, subject: subject, queue: queue))
                // Re-apply any auto-unsubscribe limit so the server still
                // stops delivery after the originally requested total count.
                if let remainingMax = remainingMax {
                    try await write(.unsubscribe(sid: sid, max: remainingMax))
                }
            } catch {
                logger.warning("Failed to resubscribe to \(subject): \(error)")
            }
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
            // Fallback: extract auth from server URLs if not explicitly set
            // This handles the case where users set servers directly instead of using url()
            for serverURL in options.servers {
                if let urlUser = serverURL.user {
                    if let urlPass = serverURL.password {
                        user = urlUser
                        pass = urlPass
                    } else {
                        token = urlUser
                    }
                    break  // Use first URL with credentials
                }
            }
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
        requestSubject: String,
        continuation: CheckedContinuation<NatsMessage, any Error>
    ) async {
        pendingRequests[replySubject] = PendingRequest(
            continuation: continuation,
            requestSubject: requestSubject
        )
    }

    @discardableResult
    private func removePendingRequest(
        replySubject: String
    ) async -> PendingRequest? {
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
