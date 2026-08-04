// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
import NIOCore
@testable import Nats

/// Coverage for refusing writes to a saturated connection.
///
/// **Scope.** Refusing before queuing is the *recoverable* half of bounding the
/// write path: nothing has been handed to the channel, so the caller can retry
/// on the same connection once it drains, and nothing is torn down.
///
/// It cannot reach a write already in flight. A sequential publisher is parked
/// inside the one write that is stuck, so it never sits between frames while
/// the buffer is over its high-water mark and the check never sees the
/// saturation. That case belongs to the write deadline — see
/// `BoundedWriteTests` — which ends the wait at the cost of the connection.
@Suite("Write Backpressure Tests", .serialized)
struct WriteBackpressureTests {

    /// Counts refusals from tasks that are never awaited.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private static let oneMegabyte: ByteBuffer = {
        var buffer = ByteBuffer()
        buffer.writeRepeatingByte(0x41, count: 1024 * 1024)
        return buffer
    }()

    private func connectedClient(
        to peer: StalledPeer,
        backpressureTimeout: Duration
    ) async throws -> NatsClient {
        var options = NatsClientOptions(servers: [peer.url])
        options.reconnect = .disabled
        options.connectTimeout = .seconds(2)
        options.writeBackpressureTimeout = backpressureTimeout
        let client = NatsClient(options: options)
        try await client.connect()
        return client
    }

    /// What backpressure actually fixes: concurrent publishers no longer pile
    /// frames into an outbound buffer that is going nowhere. Before this, each
    /// one was queued regardless and the process grew until something else
    /// broke.
    @Test("Concurrent writes to a saturated connection are refused", .timeLimit(.minutes(2)))
    func concurrentWritesAreRefused() async throws {
        let peer = try await StalledPeer.start(.sendInfoThenStopReading)
        defer { Task { await peer.stop() } }

        let client = try await connectedClient(to: peer, backpressureTimeout: .milliseconds(300))
        defer { Task { await client.close() } }

        // Deliberately NOT a task group. Some publishers are expected never to
        // return — the ones already inside `writeAndFlush` when the socket
        // stopped draining — and a task group waits for every child, so it
        // could not report the refusals that did happen. This is the same trap
        // the rest of this work exists to remove; it applies to test code too.
        let refusals = Counter()
        let payload = Self.oneMegabyte
        for _ in 0..<64 {
            Task {
                do {
                    try await client.publish("bp.concurrent", payload: payload)
                } catch {
                    if "\(error)".contains("outbound buffer stayed full") {
                        refusals.increment()
                    }
                }
            }
        }

        let deadline = ContinuousClock().now.advanced(by: .seconds(20))
        while ContinuousClock().now < deadline && refusals.value == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(
            refusals.value > 0,
            "no write was refused within 20s — backpressure never engaged while the buffer was full"
        )

        // Close inline rather than in a detached `defer { Task { … } }`.
        // The publishers this test abandons are parked inside `writeAndFlush`
        // and only unwind when the channel dies; leaving that to a detached task
        // let them — and their event-loop threads — pile up into later suites,
        // where they starved the dispatch reaping that `Process.waitUntilExit()`
        // depends on and wedged an unrelated test.
        await client.close()

    }

    /// Backpressure must not fire on a healthy connection — a false positive
    /// here would break ordinary publishing under load.
    @Test("A healthy connection is never refused", .timeLimit(.minutes(2)))
    func healthyConnectionIsNeverRefused() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14237) else { return }
        defer { server.stop() }

        var options = NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:\(server.port)")!])
        options.reconnect = .disabled
        options.writeBackpressureTimeout = .seconds(5)
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        try await client.connect()

        let payload = Self.oneMegabyte
        let outcome = await boundedly(.seconds(30)) { () -> OperationOutcome in
            await OperationOutcome {
                // Comfortably more than the 64 KB high-water mark, against a
                // real server that actually drains.
                for _ in 0..<200 {
                    try await client.publish("bp.healthy", payload: payload)
                }
            }
        }

        #expect(outcome == .succeeded, "a draining server should never trigger backpressure: \(String(describing: outcome))")
    }
}
