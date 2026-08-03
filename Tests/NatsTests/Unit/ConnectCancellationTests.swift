// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
import NIOCore
import NIOPosix
@testable import Nats

/// A TCP listener that accepts connections and then says nothing — no INFO
/// frame, ever.
///
/// This is the only state in which `connect()` reaches its handshake wait and
/// stays there: the socket is healthy and established, so no close event
/// arrives to fail the attempt. A refused connection fails earlier, inside
/// `establishConnection()`, and never gets that far.
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

/// Records a task's outcome without anyone having to `await` that task.
///
/// This matters more than it looks. `await task.value` / `await task.result`
/// are NOT cancellation-responsive — cancelling the waiter does not resume it.
/// A test that awaited the connect task directly would therefore *hang* on a
/// regression rather than fail, and `.timeLimit` could not rescue it either,
/// because the time limit is itself delivered as cancellation. Polling this box
/// keeps a regression to a 5-second failure.
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

    /// Wait up to `timeout` for an outcome, without awaiting the task itself.
    func wait(upTo timeout: Duration) async -> Result<Void, any Error>? {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            if let value { return value }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return value
    }
}

@Suite("Connect Cancellation Tests")
struct ConnectCancellationTests {

    private func makeStalledClient(_ server: SilentServer) -> NatsClient {
        NatsClient {
            $0.servers = [URL(string: "nats://127.0.0.1:\(server.port)")!]
            $0.reconnect = .disabled
        }
    }

    /// Regression: `connect()` used to wait on a bare `CheckedContinuation`
    /// with no cancellation handler. Cancelling it set the cancelled flag and
    /// then waited forever, so any caller racing it against a deadline (Nexus
    /// boot does exactly that) was left holding a task that could never finish.
    @Test("Cancelling a stalled connect unwinds instead of hanging", .timeLimit(.minutes(1)))
    func cancelledConnectUnwinds() async throws {
        let server = try await SilentServer.start()
        defer { Task { await server.stop() } }

        let client = makeStalledClient(server)
        let outcome = OutcomeBox()

        let connectTask = Task {
            do {
                try await client.connect()
                outcome.set(.success(()))
            } catch {
                outcome.set(.failure(error))
            }
        }

        // Let it get past the TCP connect and park on the handshake wait.
        try await Task.sleep(for: .milliseconds(300))
        #expect(outcome.value == nil, "connect should still be waiting on the handshake")

        connectTask.cancel()

        let result = await outcome.wait(upTo: .seconds(5))

        guard let result else {
            Issue.record("cancelled connect did not unwind within 5s — it is hung")
            return
        }
        guard case .failure = result else {
            Issue.record("expected a cancelled connect to throw, got success")
            return
        }
    }

    /// The abandoned attempt must not be left running — but it must also not
    /// poison the client.
    ///
    /// Cancellation originally routed its teardown through `close()`, which
    /// parks the state machine in the terminal `.closed` state. That made a
    /// cancelled connect unrecoverable: every subsequent `connect()` fell
    /// straight through to the `.closed` guard in `establishConnection()` and
    /// threw "Connection is closed" in milliseconds. Anything that bounds
    /// connect with a deadline — the entire reason cancellation is supported —
    /// would poison its own client on the first timeout.
    @Test("A cancelled connect leaves the client retryable, not closed", .timeLimit(.minutes(1)))
    func cancelledConnectLeavesClientRetryable() async throws {
        let server = try await SilentServer.start()
        defer { Task { await server.stop() } }

        let client = makeStalledClient(server)
        let outcome = OutcomeBox()

        let connectTask = Task {
            do {
                try await client.connect()
                outcome.set(.success(()))
            } catch {
                outcome.set(.failure(error))
            }
        }

        try await Task.sleep(for: .milliseconds(300))
        connectTask.cancel()

        guard await outcome.wait(upTo: .seconds(5)) != nil else {
            Issue.record("cancelled connect did not unwind within 5s — it is hung")
            return
        }

        // Teardown runs in the cancellation handler's own task; give it a moment.
        try await Task.sleep(for: .milliseconds(500))

        let connected = await client.isConnected
        #expect(connected == false, "the abandoned attempt should not report connected")

        let state = await client.state
        #expect(
            state != .closed,
            "a cancelled connect must not park the client in the terminal .closed state"
        )

        // The real property: a second attempt must actually be attempted, not
        // rejected out of hand. It still cannot succeed against a silent server,
        // so it should reach the handshake wait and stay there rather than
        // failing instantly off the `.closed` guard.
        let retry = OutcomeBox()
        let retryTask = Task {
            do {
                try await client.connect()
                retry.set(.success(()))
            } catch {
                retry.set(.failure(error))
            }
        }
        defer { retryTask.cancel() }

        let settled = await retry.wait(upTo: .seconds(1))
        #expect(
            settled == nil,
            "retry after a cancelled connect should reach the handshake wait, not fail immediately"
        )
    }
}
