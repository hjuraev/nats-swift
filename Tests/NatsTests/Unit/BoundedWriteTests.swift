// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
import NIOCore
@testable import Nats

/// Coverage for bounding a write already handed to the channel.
///
/// This is the half that backpressure cannot reach. A sequential publisher never
/// sits between frames while the buffer is over its high-water mark — it is
/// parked inside the one write that is stuck — so the pre-write check never sees
/// the saturation. Only a deadline enforced on the event loop can end that wait.
///
/// Abandoning the frame closes the connection, by design: bytes handed to the
/// channel cannot be recalled, and half a frame on the wire desynchronises the
/// stream for everything after it.
@Suite("Bounded Write Tests", .serialized)
struct BoundedWriteTests {

    private static let sixtyFourKilobytes: ByteBuffer = {
        var buffer = ByteBuffer()
        buffer.writeRepeatingByte(0x41, count: 64 * 1024)
        return buffer
    }()

    private func connectedClient(
        to peer: StalledPeer,
        writeTimeout: Duration
    ) async throws -> NatsClient {
        var options = NatsClientOptions(servers: [peer.url])
        options.reconnect = .disabled
        options.connectTimeout = .seconds(2)
        options.writeTimeout = writeTimeout
        // Keep backpressure out of the way so this measures the write deadline.
        options.writeBackpressureTimeout = .seconds(30)
        let client = NatsClient(options: options)
        try await client.connect()
        return client
    }

    /// The headline case. Measured before this change: 512 KiB absorbed by the
    /// kernel, then the publisher parked forever — the promise resolved only
    /// when the channel was destroyed at teardown.
    @Test("A sequential publisher to a non-reading peer now fails instead of hanging", .timeLimit(.minutes(2)))
    func sequentialPublisherIsBounded() async throws {
        let peer = try await StalledPeer.start(.sendInfoThenStopReading)
        defer { Task { await peer.stop() } }

        let client = try await connectedClient(to: peer, writeTimeout: .milliseconds(500))
        defer { Task { await client.close() } }

        let payload = Self.sixtyFourKilobytes
        let outcome = await boundedly(.seconds(15)) { () -> OperationOutcome in
            await OperationOutcome {
                for _ in 0..<4096 {
                    try await client.publish("bounded.seq", payload: payload)
                }
            }
        }

        guard let outcome else {
            Issue.record("sequential publisher never returned — the write is still unbounded")
            return
        }
        guard let message = outcome.message else {
            Issue.record("expected the stalled write to fail, but all 4096 frames succeeded")
            return
        }
        #expect(
            message.contains("did not reach the socket"),
            "expected a write-timeout failure, got: \(message)"
        )

        // Close inline rather than in a detached `defer { Task { … } }`.
        // The publishers this test abandons are parked inside `writeAndFlush`
        // and only unwind when the channel dies; leaving that to a detached task
        // let them — and their event-loop threads — pile up into later suites,
        // where they starved the dispatch reaping that `Process.waitUntilExit()`
        // depends on and wedged an unrelated test.
        await client.close()

    }

    /// Abandoning a frame must take the connection with it — leaving a
    /// desynchronised stream in use would corrupt every later operation.
    @Test("An abandoned write closes the connection", .timeLimit(.minutes(2)))
    func abandonedWriteClosesTheConnection() async throws {
        let peer = try await StalledPeer.start(.sendInfoThenStopReading)
        defer { Task { await peer.stop() } }

        let client = try await connectedClient(to: peer, writeTimeout: .milliseconds(500))
        defer { Task { await client.close() } }

        let connectedBefore = await client.isConnected
        #expect(connectedBefore, "precondition: the client should be connected")

        let payload = Self.sixtyFourKilobytes
        _ = await boundedly(.seconds(15)) { () -> OperationOutcome in
            await OperationOutcome {
                for _ in 0..<4096 {
                    try await client.publish("bounded.teardown", payload: payload)
                }
            }
        }

        // Teardown runs inside the failing write, but the close event lands
        // asynchronously.
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        var stillConnected = await client.isConnected
        while ContinuousClock().now < deadline && stillConnected {
            try await Task.sleep(for: .milliseconds(50))
            stillConnected = await client.isConnected
        }

        #expect(!stillConnected, "the connection carrying an abandoned frame was left in use")

        // And it must not be the terminal `.closed` state — reconnect has to
        // remain possible, which is the lesson from fbf57ab.
        let state = await client.state
        #expect(state != .closed, "an abandoned write must not permanently brick the client")

        // Close inline rather than in a detached `defer { Task { … } }`.
        // The publishers this test abandons are parked inside `writeAndFlush`
        // and only unwind when the channel dies; leaving that to a detached task
        // let them — and their event-loop threads — pile up into later suites,
        // where they starved the dispatch reaping that `Process.waitUntilExit()`
        // depends on and wedged an unrelated test.
        await client.close()

    }

    /// The deadline must not fire on a connection that is simply working.
    @Test("A healthy connection is never cut off by writeTimeout", .timeLimit(.minutes(2)))
    func healthyConnectionIsUnaffected() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14238) else { return }
        defer { server.stop() }

        var options = NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:\(server.port)")!])
        options.reconnect = .disabled
        options.writeTimeout = .seconds(5)
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        try await client.connect()

        let payload = Self.sixtyFourKilobytes
        let outcome = await boundedly(.seconds(30)) { () -> OperationOutcome in
            await OperationOutcome {
                for _ in 0..<2000 {
                    try await client.publish("bounded.healthy", payload: payload)
                }
            }
        }

        #expect(outcome == .succeeded, "a draining server should never trip writeTimeout: \(String(describing: outcome))")

        let connected = await client.isConnected
        #expect(connected, "healthy publishing must not tear the connection down")
    }

    /// Cancelling a write has to unwind rather than wait for the deadline —
    /// and carries the same teardown, for the same reason.
    @Test("Cancelling a stalled write unwinds promptly", .timeLimit(.minutes(2)))
    func cancelledWriteUnwinds() async throws {
        let peer = try await StalledPeer.start(.sendInfoThenStopReading)
        defer { Task { await peer.stop() } }

        // Deadline far enough out that only cancellation can end this.
        let client = try await connectedClient(to: peer, writeTimeout: .seconds(3600))
        defer { Task { await client.close() } }

        let finished = ResultBox<OperationOutcome>()
        let payload = Self.sixtyFourKilobytes

        let publisher = Task {
            finished.set(await OperationOutcome {
                for _ in 0..<4096 {
                    try await client.publish("bounded.cancel", payload: payload)
                }
            })
        }

        // Let it saturate and park inside a write.
        try await Task.sleep(for: .seconds(1))
        #expect(finished.value == nil, "precondition: the publisher should be stuck in a write")

        publisher.cancel()

        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while ContinuousClock().now < deadline && finished.value == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(
            finished.value?.isFailure == true,
            "cancelled write did not unwind within 5s: \(String(describing: finished.value))"
        )

        // Close inline rather than in a detached `defer { Task { … } }`.
        // The publishers this test abandons are parked inside `writeAndFlush`
        // and only unwind when the channel dies; leaving that to a detached task
        // let them — and their event-loop threads — pile up into later suites,
        // where they starved the dispatch reaping that `Process.waitUntilExit()`
        // depends on and wedged an unrelated test.
        await client.close()

    }
}
