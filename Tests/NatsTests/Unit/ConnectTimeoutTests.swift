// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
import NIOCore
import NIOPosix
@testable import Nats

/// A TCP listener that accepts connections and then says nothing — no INFO
/// frame, ever. The only state in which `connect()` reaches its handshake wait
/// and stays there.
private final class SilentServer: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    let port: Int

    private init(group: MultiThreadedEventLoopGroup, channel: Channel, port: Int) {
        self.group = group
        self.channel = channel
        self.port = port
    }

    static func start() async throws -> SilentServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .get()

        guard let port = channel.localAddress?.port else {
            try? await channel.close()
            try? await group.shutdownGracefully()
            throw ConnectionError.noServersAvailable
        }
        return SilentServer(group: group, channel: channel, port: port)
    }

    func stop() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }
}

/// Records a connect's outcome so a test can *observe* whether it ended without
/// ever cancelling it.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, any Error>?

    func set(_ value: Result<Void, any Error>) {
        lock.lock(); defer { lock.unlock() }
        if outcome == nil { outcome = value }
    }

    var value: Result<Void, any Error>? {
        lock.lock(); defer { lock.unlock() }
        return outcome
    }
}

@Suite("Connect Timeout Tests")
struct ConnectTimeoutTests {

    private func client(port: Int, timeout: Duration, reconnect: ReconnectPolicy = .disabled) -> NatsClient {
        NatsClient {
            $0.servers = [URL(string: "nats://127.0.0.1:\(port)")!]
            $0.connectTimeout = timeout
            $0.reconnect = reconnect
        }
    }

    /// Start a connect and watch, up to `limit`, for it to finish **on its own**.
    ///
    /// This is an observation, not a deadline: the connect task is never
    /// cancelled before the result is read, so nothing here can substitute for
    /// the client's own timeout — which is exactly the property under test. The
    /// cancel afterwards is cleanup only.
    ///
    /// Reading through a box rather than `await task.value` is deliberate: that
    /// await is not cancellation-responsive, so a regression would hang the test
    /// target instead of failing it, and `.timeLimit` could not rescue it either
    /// because the time limit is itself delivered as cancellation.
    private func observeConnect(
        _ client: NatsClient,
        upTo limit: Duration = .seconds(5)
    ) async -> (outcome: Result<Void, any Error>?, elapsed: Duration) {
        let box = OutcomeBox()
        let start = ContinuousClock.now

        let task = Task {
            do {
                try await client.connect()
                box.set(.success(()))
            } catch {
                box.set(.failure(error))
            }
        }

        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline, box.value == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let elapsed = ContinuousClock.now - start
        let outcome = box.value
        task.cancel()  // cleanup only — after the observation
        return (outcome, elapsed)
    }

    // MARK: - Bounded, not merely cancellable

    /// The point of the feature: `connect()` ends on its own.
    ///
    /// Deliberately wraps `connect()` in NO timeout of its own — doing so would
    /// only re-test the cancellation path. Correctness must not depend on every
    /// call site remembering a deadline.
    @Test("A stalled connect times out with no external canceller", .timeLimit(.minutes(1)))
    func stalledConnectTimesOutOnItsOwn() async throws {
        let server = try await SilentServer.start()
        defer { Task { await server.stop() } }

        let client = client(port: server.port, timeout: .milliseconds(200))
        let (outcome, elapsed) = await observeConnect(client)

        guard let outcome else {
            Issue.record("connect never ended on its own within 5s — it is unbounded")
            return
        }
        guard case .failure(let error) = outcome else {
            Issue.record("expected a stalled connect to fail, got success")
            return
        }
        #expect(error is ConnectionError, "expected ConnectionError, got \(type(of: error))")
        #expect(elapsed >= .milliseconds(200), "connect returned before its own deadline: \(elapsed)")
        #expect(elapsed < .seconds(2), "connect overran its deadline: \(elapsed)")
    }

    /// The deadline is one budget across TCP + handshake, so it should be
    /// honoured within a small tolerance rather than doubled.
    @Test("The deadline is a single budget across both phases", .timeLimit(.minutes(1)))
    func deadlineIsOneBudget() async throws {
        let server = try await SilentServer.start()
        defer { Task { await server.stop() } }

        let client = client(port: server.port, timeout: .milliseconds(400))
        let (outcome, elapsed) = await observeConnect(client)

        #expect(outcome != nil, "connect never ended on its own — it is unbounded")
        // Bounding each phase separately would allow ~800ms here.
        #expect(elapsed < .milliseconds(700), "looks like each phase got its own budget: \(elapsed)")
    }

    /// A timed-out attempt must be as retryable as a failed one — the same
    /// property that `fbf57ab` restored for cancellation. A timeout reaches the
    /// identical teardown path, so it needs the identical guarantee.
    @Test("A timed-out connect leaves the client retryable", .timeLimit(.minutes(1)))
    func timedOutConnectLeavesClientRetryable() async throws {
        let server = try await SilentServer.start()
        defer { Task { await server.stop() } }

        let client = client(port: server.port, timeout: .milliseconds(200))

        let (first, _) = await observeConnect(client)
        #expect(first != nil, "first connect never ended on its own")

        let state = await client.state
        #expect(
            state != .closed,
            "a timed-out connect must not park the client in the terminal .closed state"
        )

        // A second attempt must actually be attempted, and must time out the
        // same way rather than failing instantly off the `.closed` guard.
        let (second, elapsed) = await observeConnect(client)
        #expect(second != nil, "retry never ended on its own")
        #expect(
            elapsed >= .milliseconds(200),
            "retry after a timeout failed instantly (\(elapsed)) — the client was poisoned"
        )
    }

    /// The reconnect loop shares the budget. Without it a stalled reconnect
    /// wedges the loop and the client never retries, so the policy's attempt
    /// count is silently never consumed.
    @Test("A stalled reconnect does not wedge the reconnect loop", .timeLimit(.minutes(1)))
    func stalledReconnectDoesNotWedgeLoop() async throws {
        let server = try await SilentServer.start()
        defer { Task { await server.stop() } }

        var policy = ReconnectPolicy()
        policy.enabled = true
        policy.maxAttempts = 2

        let client = client(port: server.port, timeout: .milliseconds(200), reconnect: policy)

        // The initial connect stalls and must still end on its own even with
        // reconnection enabled.
        let (outcome, elapsed) = await observeConnect(client)

        #expect(outcome != nil, "connect with reconnect enabled did not end on its own: \(elapsed)")
    }

    // MARK: - No cost on the healthy path

    /// The timer must not add measurable latency to a normal connect, and must
    /// not double-resume a connect that lands just before the deadline.
    @Test("A normal connect is unaffected by the timer", .timeLimit(.minutes(1)))
    func normalConnectUnaffected() async throws {
        let url = ProcessInfo.processInfo.environment["NATS_URL"] ?? "nats://localhost:4222"
        guard let parsed = URL(string: url), let port = parsed.port else { return }

        // Only meaningful against a live broker; skip quietly when absent so the
        // suite still runs standalone.
        guard await Self.isReachable(host: parsed.host ?? "localhost", port: port) else { return }

        let client = NatsClient {
            $0.servers = [parsed]
            $0.connectTimeout = .seconds(5)
            $0.reconnect = .disabled
        }

        let start = ContinuousClock.now
        try await client.connect()
        let elapsed = ContinuousClock.now - start

        let connected = await client.isConnected
        #expect(connected, "expected a healthy connect")
        #expect(elapsed < .seconds(2), "connect took \(elapsed) — the timer should add nothing")

        // Outlive the deadline: a late timer firing must not disturb a
        // connection that already settled, nor double-resume its continuation.
        try await Task.sleep(for: .seconds(6))
        let stillConnected = await client.isConnected
        #expect(stillConnected, "the connect timer disturbed an established connection")

        await client.close()
    }

    private static func isReachable(host: String, port: Int) async -> Bool {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        do {
            let channel = try await ClientBootstrap(group: group)
                .connectTimeout(.milliseconds(500))
                .connect(host: host, port: port).get()
            try? await channel.close()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Option plumbing

    @Test("connectTimeout defaults to 5s and is configurable")
    func optionDefaultsAndOverrides() {
        #expect(NatsClientOptions().connectTimeout == .seconds(5))

        var options = NatsClientOptions()
        options.connectTimeout = .milliseconds(750)
        #expect(options.connectTimeout == .milliseconds(750))
    }

    /// Guards the conversion the connect deadline and the ping timer both rely
    /// on. NIO supplies `TimeAmount(_ duration:)`; the point here is that we use
    /// it rather than hand-rolling `components.seconds * 1_000_000_000`, which
    /// silently floors every sub-second value to zero — no timeout at all.
    @Test("Duration converts to TimeAmount without losing sub-second precision")
    func durationConversionKeepsSubSecond() {
        #expect(TimeAmount(Duration.milliseconds(500)).nanoseconds == 500_000_000)
        #expect(TimeAmount(Duration.milliseconds(1)).nanoseconds == 1_000_000)
        #expect(TimeAmount(Duration.seconds(2)).nanoseconds == 2_000_000_000)
        #expect(TimeAmount(Duration.milliseconds(1500)).nanoseconds == 1_500_000_000)
        #expect(TimeAmount(Duration.zero).nanoseconds == 0)
    }
}
