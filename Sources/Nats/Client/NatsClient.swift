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

    // Whether this client created its event-loop group and is therefore
    // responsible for shutting it down. A group supplied through
    // `NatsClientOptions.eventLoopGroup` belongs to the caller: shutting that
    // one down on close() would take out every other client sharing it, which
    // is a worse failure than the per-client group it replaces.
    private let ownsEventLoopGroup: Bool
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

    // Server frames that arrived before `establishConnection` had assigned
    // `self.channel`. The pipeline is wired before the connect future resolves,
    // so a fast server's INFO can beat the assignment to the actor.
    private var pendingServerOps: [ServerOp] = []

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

    // Whether the TLS handshake for the current attempt has actually completed.
    //
    // `upgradeToTLS()` returns as soon as the handler is in the pipeline, not
    // when the handshake finishes — NIOSSL buffers outbound writes until then.
    // The attempt is already bounded (the connect deadline covers it), but
    // without this flag a stalled handshake reports a bare "connection timeout",
    // indistinguishable from a slow TCP connect or a server that never sent
    // INFO. Knowing which one it was is the difference between a five-minute
    // diagnosis and a five-day one.
    private var tlsHandshakeCompleted: Bool = false

    /// Settle-once guard shared by a bounded write's completion, its deadline
    /// and its cancellation handler. All three run on the same event loop, so
    /// the lock is only here to satisfy `Sendable`, not for contention.
    private final class WriteSettleFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false

        /// Returns true to exactly one caller.
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if settled { return false }
            settled = true
            return true
        }
    }

    /// How often a blocked write re-checks whether the connection has drained.
    private static let writabilityPollInterval: Duration = .milliseconds(5)

    /// Window allowed for in-flight messages to land during `drain()`, capped
    /// by the caller's `drainTimeout`.
    private static let drainSettleWindow: Duration = .milliseconds(500)

    /// How long `close()` waits for a cancelled reconnect attempt to stop
    /// before proceeding without it.
    private static let reconnectionStopTimeout: Duration = .seconds(2)

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
        self.eventLoopGroup = options.eventLoopGroup
        self.ownsEventLoopGroup = options.eventLoopGroup == nil
        self.inboxPrefix = "\(options.inboxPrefix).\(Subject.randomToken())"
        self.reconnectionState = ReconnectionState(policy: options.reconnect)
    }

    /// Create a new NATS client with configuration closure
    public init(_ configure: (inout NatsClientOptions) -> Void) {
        var opts = NatsClientOptions()
        configure(&opts)
        self.options = opts
        self.logger = opts.logger
        self.eventLoopGroup = opts.eventLoopGroup
        self.ownsEventLoopGroup = opts.eventLoopGroup == nil
        self.inboxPrefix = "\(opts.inboxPrefix).\(Subject.randomToken())"
        self.reconnectionState = ReconnectionState(policy: opts.reconnect)
    }

    /// Create a new NATS client with options
    public init(options: NatsClientOptions) {
        self.options = options
        self.logger = options.logger
        self.eventLoopGroup = options.eventLoopGroup
        self.ownsEventLoopGroup = options.eventLoopGroup == nil
        self.inboxPrefix = "\(options.inboxPrefix).\(Subject.randomToken())"
        self.reconnectionState = ReconnectionState(policy: options.reconnect)
    }

    /// The event-loop group this client is currently using, if any.
    ///
    /// Test-only. Exposed so the ownership contract in
    /// `NatsClientOptions.eventLoopGroup` can be asserted rather than assumed —
    /// whether `close()` tore a group down is not observable from the public
    /// surface.
    internal var eventLoopGroupForTesting: EventLoopGroup? {
        eventLoopGroup
    }

    // MARK: - Connection Lifecycle

    /// Connect to the NATS server
    public func connect() async throws(ConnectionError) {
        // `.closed` is terminal in ConnectionStateMachine — no event transitions
        // out of it. This guard used to admit it, so `transition(on: .connect)`
        // silently did nothing and the attempt fell through to
        // `establishConnection()`'s own `.closed` check, surfacing as a bare
        // "Connection is closed" several frames from the real cause. Say what
        // actually happened instead.
        if stateMachine.state == .closed {
            logger.error("connect() called on a closed client; NatsClient is single-use — create a new instance after close()")
            throw ConnectionError.closed
        }

        guard stateMachine.state == .disconnected else {
            logger.warning("Already connected or connecting")
            return
        }

        _ = stateMachine.transition(on: .connect)
        logger.info("Connecting to NATS servers: \(options.servers.map { $0.sanitizedDescription })")

        // One budget across both phases, so `connectTimeout` means what it says.
        // Bounding each phase separately would let a slow-but-not-stalled TCP
        // connect plus a slow handshake take twice the configured maximum.
        let deadline = ContinuousClock.now.advanced(by: options.connectTimeout)

        beginHandshake()
        do {
            try await establishConnection()

            // Wait for the handshake to complete (INFO received, CONNECT sent)
            try await waitForHandshake(timeout: remaining(until: deadline))
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
        tlsHandshakeCompleted = false
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

    /// Time left until `deadline`, never negative.
    private func remaining(until deadline: ContinuousClock.Instant) -> Duration {
        let left = ContinuousClock.now.duration(to: deadline)
        return left > .zero ? left : .zero
    }

    /// Suspend until the handshake settles, bounded by `timeout` and honouring
    /// cancellation.
    ///
    /// Two distinct properties, both required:
    ///
    /// - *Cancellable* — the wait unwinds when the enclosing task is cancelled.
    ///   The bare `withCheckedThrowingContinuation` this replaces was not:
    ///   cancelling a connect requested cancellation and then waited forever.
    /// - *Bounded* — something fires on its own, with no external canceller. A
    ///   server that accepts the socket and never sends INFO must not be able to
    ///   block a connect indefinitely just because the caller forgot a deadline.
    private func waitForHandshake(timeout: Duration) async throws {
        let timer = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return  // cancelled: the handshake already settled
            }
            await self?.failHandshakeOnDeadline(after: timeout)
        }
        defer { timer.cancel() }

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
            Task { await self.failHandshake(with: CancellationError()) }
        }
    }

    /// Fail an in-flight handshake because its deadline expired, naming the
    /// phase that actually stalled.
    private func failHandshakeOnDeadline(after timeout: Duration) async {
        await failHandshake(with: connectDeadlineError(after: timeout))
    }

    /// Fail an in-flight handshake wait and tear down the half-open attempt.
    ///
    /// Shared by cancellation and by the connect deadline. Delivery goes through
    /// `settleHandshake`, so this is first-writer-wins on an actor: whichever of
    /// {handshake, timeout, cancellation} arrives first owns the outcome and the
    /// others become no-ops. That is what stops a connect which succeeds just
    /// before the deadline from being double-resumed — and, because
    /// `settleHandshake` parks a result that outruns its waiter, a timeout that
    /// fires before `waitForHandshake` has stored its continuation is collected
    /// rather than lost.
    ///
    /// Deliberately does NOT call `close()`. `close()` transitions to `.closed`,
    /// which the state machine treats as terminal — no event transitions out of
    /// it — so routing failure through it left the client permanently unusable:
    /// every later `connect()` fell straight through to
    /// `establishConnection()`'s `.closed` guard and threw "Connection is
    /// closed" in milliseconds. An abandoned attempt has to be exactly as
    /// retryable as a failed one, so this tears down only the half-open socket
    /// and lets `connect()`'s own catch put the state machine back in
    /// `.disconnected`, which is what an ordinary connect failure does. That
    /// matters more now that a *timeout* reaches this path, not just an explicit
    /// cancellation.
    ///
    /// The event-loop group is left up on purpose: `establishConnection()`
    /// reuses it across attempts, and `close()` remains the way to release it.
    /// That matches how a refused connect already behaves.
    private func failHandshake(with error: any Error) async {
        guard handshakeInFlight else { return }

        settleHandshake(.failure(error))
        logger.info("Connect attempt abandoned: \(error)")

        if let channel {
            try? await channel.close()
        }
        channel = nil
        connectionHandler = nil
    }

    /// Close the connection
    public func close() async {
        logger.info("Closing NATS connection")

        // Cancel any ongoing reconnection first, and *wait for it to stop*.
        //
        // Cancelling without awaiting let a suspended reconnect attempt resume
        // after `eventLoopGroup` had already been nil'd below, at which point
        // `establishConnection()` built a fresh group that nothing would ever
        // shut down — one leaked group and thread per occurrence. The wait is
        // bounded so a reconnect wedged on a non-cancellable operation delays
        // close rather than blocking it forever.
        if let reconnection = reconnectionTask {
            reconnectionTask = nil
            reconnection.cancel()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = await reconnection.value }
                group.addTask { try? await Task.sleep(for: Self.reconnectionStopTimeout) }
                _ = await group.next()
                group.cancelAll()
            }
        }

        _ = stateMachine.transition(on: .close)

        // Finish all subscriptions
        await subscriptionManager.finishAll()

        // Bump the generation so a fresh connection on this client gets a
        // working subscription manager. `finishAll()` latches `isClosed`, which
        // silently discards every later message; without this reset the manager
        // stayed dead for the lifetime of the client.
        await subscriptionManager.reopen()

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
        pendingServerOps.removeAll()

        // Shutdown the event-loop group only if it is ours. An injected group
        // outlives the client by contract — see NatsClientOptions.eventLoopGroup.
        if ownsEventLoopGroup {
            if let group = eventLoopGroup {
                try? await group.shutdownGracefully()
            }
            eventLoopGroup = nil
        }
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

        // `drainTimeout` bounds the whole drain. It was previously declared,
        // defaulted and assigned but never read by any code path, while drain
        // used a hard-coded 500 ms settle window — an advertised timeout that
        // did nothing.
        //
        // Caveat: an individual UNSUB write is still unbounded (see the write
        // path work), so a wedged socket can overrun this deadline inside one
        // write. Bounding the loop and the settle window is what can be done
        // without a bounded-write primitive.
        let deadline = ContinuousClock.now.advanced(by: options.drainTimeout)

        // Get all active subscriptions before we start draining
        let activeSubscriptions = await subscriptionManager.getAllSubscriptions()

        // Send UNSUB for all subscriptions to stop receiving new messages from server
        for (sid, _, _, _) in activeSubscriptions {
            guard ContinuousClock.now < deadline else {
                logger.warning("Drain timeout reached with subscriptions still to unsubscribe; closing anyway")
                break
            }
            try? await write(.unsubscribe(sid: sid, max: nil))
            await subscriptionManager.markDraining(sid: sid)
        }

        // Brief window for in-flight messages to arrive and be delivered, capped
        // by whatever is left of the drain budget.
        let settleWindow = min(Self.drainSettleWindow, remaining(until: deadline))
        try? await Task.sleep(for: settleWindow)

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
        pendingServerOps.removeAll()

        // Close the previous connection's channel so a dropped or
        // failed-handshake socket isn't left dangling on the event loop.
        if let oldChannel = channel {
            try? await oldChannel.close()
            self.channel = nil
        }
        self.connectionHandler = nil

        // Reuse the EventLoopGroup across reconnect attempts — it is only shut
        // down by close(), and then only if this client created it. Creating a
        // fresh group every attempt would leak a group and its backing thread
        // on each reconnect. An injected group arrives already set on
        // `eventLoopGroup`, so it takes the reuse branch below.
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
            // Without this the TCP phase falls back to NIO's own default rather
            // than anything the caller configured, so a black-holed SYN could
            // outlast connectTimeout entirely.
            .connectTimeout(TimeAmount(options.connectTimeout))
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            // What makes `channel.isWritable` meaningful. Without explicit
            // marks the client had no signal that a peer had stopped reading,
            // and every frame was queued regardless.
            .channelOption(ChannelOptions.writeBufferWaterMark, value: options.writeBufferWaterMark)
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
            await drainPendingServerOps()
        } catch {
            throw ConnectionError.connectionRefused(host: host, port: port)
        }
    }

    private func handleServerOp(_ op: ServerOp, generation: UInt64) async {
        // Drop frames from a superseded connection (e.g. a late INFO from a
        // channel being torn down during reconnect).
        guard generation == connectionGeneration else { return }

        // `establishConnection` installs this handler in the pipeline *before*
        // `bootstrap.connect()` resolves and assigns `self.channel`, so on a
        // fast or loaded connection the server's INFO can reach the actor while
        // the client still has no channel to answer on. Acting on it there made
        // the CONNECT write fail `write()`'s own nil-channel guard and surface
        // as "Failed to send CONNECT: Connection is closed" — a client-side
        // race misreported as the server hanging up. Park the frame; assigning
        // the channel drains this queue in order.
        if channel == nil && handshakeInFlight {
            pendingServerOps.append(op)
            return
        }

        await process(op)
    }

    /// Deliver frames that arrived before the channel was registered.
    private func drainPendingServerOps() async {
        guard !pendingServerOps.isEmpty else { return }
        let queued = pendingServerOps
        pendingServerOps.removeAll()
        for op in queued {
            await process(op)
        }
    }

    private func process(_ op: ServerOp) async {
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
            // Tear down the attempt, not the client. Routing this through
            // close() parked the state machine in the terminal `.closed` state,
            // so a TLS misconfiguration — or any transient TLS failure —
            // permanently bricked the instance. Same defect fbf57ab fixed for
            // cancellation, reached by a different path.
            await failHandshake(with: ConnectionError.tlsRequired)
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
                // See above: fail the attempt, keep the client usable.
                await failHandshake(with: ConnectionError.tlsHandshakeFailed(reason: error.localizedDescription))
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
                let interval = TimeAmount(options.pingInterval)
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

        // Watch for the handshake actually completing. Adding the SSL handler
        // only *starts* it; everything written before it finishes sits in
        // NIOSSL's buffer.
        //
        // Inserted first and then displaced by the SSL handler, so the pipeline
        // ends up [ssl, observer, ...] — the observer sits directly downstream
        // of the handler whose event it is watching for.
        let generation = connectionGeneration
        let observer = TLSHandshakeObserver { [weak self] in
            Task { await self?.markTLSHandshakeCompleted(generation: generation) }
        }
        try await channel.pipeline.addHandler(observer, position: .first).get()

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
        } else if wasConnected {
            // Nothing is going to restore this connection. Consumers were left
            // suspended on `for await msg in subscription` forever — a
            // subscription that looked alive and could never deliver again.
            // Silence is the worst possible report, so end the streams.
            //
            // Only in this branch: when a reconnect *is* coming, `resubscribeAll`
            // restores these same subscriptions and finishing them would destroy
            // the thing being restored.
            logger.info("Connection lost and reconnection is disabled; finishing all subscriptions")
            await subscriptionManager.finishAll()

            // Clear the closed latch so a caller who reconnects by hand gets a
            // working manager rather than one that silently discards everything.
            await subscriptionManager.reopen()
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

                // Same one-attempt budget as the initial connect. Without it a
                // reconnect that stalls mid-handshake wedges this loop and no
                // further attempt is ever made — the client stays down for good
                // even though the policy has attempts left.
                let deadline = ContinuousClock.now.advanced(by: options.connectTimeout)

                beginHandshake()
                try await establishConnection()

                // Wait for the NATS handshake to complete (INFO received,
                // CONNECT sent and confirmed) before resubscribing.
                // establishConnection() only completes the TCP connect — SUB
                // frames sent before CONNECT race the handshake and are
                // dropped by the server. handleInfo() settles this wait once
                // the session is fully connected.
                try await waitForHandshake(timeout: remaining(until: deadline))

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

        // Refuse before queuing when the connection is saturated.
        //
        // This is the recoverable half of bounding writes. Once bytes are handed
        // to `writeAndFlush` they cannot be un-queued — abandoning a partially
        // flushed frame would corrupt the stream for every later operation — so
        // the only safe place to say no is *before* the write. A peer that stops
        // reading previously turned into unbounded buffering here.
        if !channel.isWritable {
            let waited = try await awaitWritable(channel)
            if !waited {
                throw ConnectionError.backpressured(after: options.writeBackpressureTimeout)
            }
        }

        try await flush(op, on: channel)
    }

    /// Write one frame with a deadline, honouring cancellation.
    ///
    /// `channel.writeAndFlush(op)` alone is unbounded *and* non-cancellable:
    /// NIO's async bridge awaits the promise, which completes only when the
    /// bytes reach the socket. Against a peer that accepts and stops reading,
    /// that promise is never fulfilled — measured: 512 KiB absorbed by the
    /// kernel, then the next frame parks forever and resolves only when the
    /// channel is destroyed.
    ///
    /// The deadline is enforced by the event loop, because a Swift-side race
    /// would return while the write stayed pending. Whoever settles first —
    /// completion, deadline, or cancellation — owns the outcome.
    ///
    /// **Abandoning a write closes the connection.** Bytes already handed to
    /// the channel cannot be recalled, so a frame abandoned midway leaves the
    /// stream desynchronised; every later operation would land at a boundary
    /// the server no longer agrees with. Tearing down is the price of bounding
    /// a write at all, and it has a useful side effect: closing fails the
    /// orphaned promise, so the abandoned write does not leak.
    private func flush(_ op: ClientOp, on channel: Channel) async throws {
        let timeout = options.writeTimeout
        let eventLoop = channel.eventLoop
        let outcome = eventLoop.makePromise(of: Void.self)
        let settled = WriteSettleFlag()

        let deadline = eventLoop.scheduleTask(in: TimeAmount(timeout)) {
            guard settled.claim() else { return }
            outcome.fail(ConnectionError.writeTimedOut(after: timeout))
        }

        channel.writeAndFlush(op).whenComplete { result in
            guard settled.claim() else { return }
            deadline.cancel()
            outcome.completeWith(result)
        }

        do {
            try await withTaskCancellationHandler {
                try await outcome.futureResult.get()
            } onCancel: {
                eventLoop.execute {
                    guard settled.claim() else { return }
                    deadline.cancel()
                    outcome.fail(CancellationError())
                }
            }
        } catch {
            if Self.abandonsFrame(error) {
                await tearDownAbandonedWrite(channel)
            }
            throw error
        }
    }

    /// Record that the current attempt's TLS handshake finished.
    private func markTLSHandshakeCompleted(generation: UInt64) {
        guard generation == connectionGeneration else { return }
        tlsHandshakeCompleted = true
        logger.debug("TLS handshake completed")
    }

    /// The error to report when the connect deadline expires.
    ///
    /// Attribution, not boundedness: the deadline already fires correctly. But
    /// "connection timeout" covers a stalled TCP connect, a server that never
    /// sent INFO, and a TLS peer that never answered the ClientHello — three
    /// very different things to go and look at.
    private func connectDeadlineError(after timeout: Duration) -> ConnectionError {
        if usingTLS && !tlsHandshakeCompleted {
            return .tlsHandshakeFailed(
                reason: "TLS handshake did not complete within \(timeout)"
            )
        }
        return .timeout(after: timeout)
    }

    /// Whether this failure means a frame was abandoned mid-flight, as opposed
    /// to never having been handed over or having failed outright.
    private static func abandonsFrame(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let connectionError = error as? ConnectionError,
           case .writeTimedOut = connectionError {
            return true
        }
        return false
    }

    /// Close the connection a frame was abandoned on.
    ///
    /// Deliberately closes the *channel* rather than calling `close()`: the
    /// latter parks the state machine in the terminal `.closed` state and would
    /// make the client permanently unusable. Closing the channel routes through
    /// `handleConnectionClose`, which returns the state to `.disconnected` and
    /// starts reconnection when it is enabled.
    private func tearDownAbandonedWrite(_ channel: Channel) async {
        guard self.channel === channel else {
            return  // already replaced by a newer attempt; nothing to tear down
        }

        logger.error("Abandoned an in-flight write; closing the connection because a partly flushed frame leaves the stream unusable")
        try? await channel.close()
    }

    /// Wait for a saturated connection to drain, up to `writeBackpressureTimeout`.
    ///
    /// Polls rather than waiting on a writability event. That is a deliberate
    /// trade: this path only runs when the connection is *already* blocked, so
    /// the poll interval is noise next to the stall it is measuring, and it
    /// avoids a second continuation handoff — the exact machinery that produced
    /// the lost-wakeup and double-resume bugs on the handshake path.
    ///
    /// Returns false if the connection never became writable in time.
    private func awaitWritable(_ channel: Channel) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: options.writeBackpressureTimeout)
        logger.debug("Connection is saturated; waiting for it to drain before writing")

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()

            // A connection that dies while we wait must fail the write rather
            // than spin out the full timeout.
            guard self.channel === channel else {
                throw ConnectionError.closed
            }
            if channel.isWritable {
                return true
            }
            try await Task.sleep(for: Self.writabilityPollInterval)
        }
        return channel.isWritable
    }
}

// MARK: - Client Statistics

public struct ClientStats: Sendable {
    public let messagesSent: UInt64
    public let messagesReceived: UInt64
}
