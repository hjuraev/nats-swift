// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
import NIOCore
@testable import Nats

/// Lifecycle defects that were reachable through ordinary use but invisible to
/// a suite that only asserted the happy path.
@Suite("Client Lifecycle Correctness Tests", .serialized)
struct ClientLifecycleCorrectnessTests {

    // MARK: - connect() on a closed client

    /// `.closed` is terminal, but `connect()`'s guard admitted it. The
    /// transition silently no-opped and the attempt fell through to
    /// `establishConnection()`'s own check, so the caller got a bare
    /// "Connection is closed" from several frames away — the same string a
    /// genuine mid-flight disconnect produces, which is what made the
    /// downstream report so hard to place.
    @Test("connect() on a closed client fails immediately and explicitly", .timeLimit(.minutes(1)))
    func connectOnClosedClientIsRejected() async throws {
        let client = NatsClient { $0.reconnect = .disabled }
        await client.close()

        let state = await client.state
        #expect(state == .closed)

        let outcome = await boundedly(.seconds(2)) {
            await OperationOutcome { try await client.connect() }
        }

        guard let outcome else {
            Issue.record("connect() on a closed client did not return within 2s")
            return
        }
        #expect(outcome.isFailure, "connect() on a closed client must throw, not silently return")
    }

    /// The guard must still let a fresh client through — a too-eager rejection
    /// would break every ordinary connect.
    @Test("A fresh client is not rejected by the closed guard", .timeLimit(.minutes(1)))
    func freshClientIsNotRejected() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14231) else { return }
        defer { server.stop() }

        var options = NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:\(server.port)")!])
        options.reconnect = .disabled
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        let outcome = await boundedly(.seconds(5)) {
            await OperationOutcome { try await client.connect() }
        }
        #expect(outcome == .succeeded, "fresh connect failed: \(String(describing: outcome))")
    }

    // MARK: - Subscription manager reuse

    /// Direct coverage for the `isClosed` latch.
    ///
    /// `finishAll()` sets it and nothing ever cleared it, so the manager
    /// silently discarded every subsequent message — a subscription that looked
    /// healthy and delivered nothing.
    ///
    /// This is latent rather than live today: `finishAll()` is only reached from
    /// `close()`, and a closed client is terminal, so no caller can currently
    /// observe it. It becomes a live bug the moment a manager outlives one
    /// connection — which is exactly what making `.closed` re-openable would
    /// do. Fixed now so it is not a landmine for that work.
    @Test("A reopened subscription manager delivers again", .timeLimit(.minutes(1)))
    func reopenClearsTheClosedLatch() async throws {
        let manager = SubscriptionManager()

        @Sendable func subscribeAndDeliver() async -> Bool {
            let sid = await manager.generateSid()
            let (stream, continuation) = AsyncStream<NatsMessage>.makeStream()
            await manager.register(sid: sid, subject: "latch.test", queueGroup: nil, continuation: continuation)

            _ = await manager.deliver(
                sid: sid,
                message: NatsMessage(subject: "latch.test", buffer: ByteBuffer(string: "x"), sid: sid)
            )

            var iterator = stream.makeAsyncIterator()
            let received = await iterator.next()
            return received != nil
        }

        // Before any close, delivery works.
        let beforeClose = await boundedly(.seconds(2)) { await subscribeAndDeliver() }
        #expect(beforeClose == true, "baseline delivery failed")

        // finishAll() latches the manager shut: deliver() returns true but
        // discards, so the stream never yields and the wait times out.
        await manager.finishAll()
        let whileLatched = await boundedly(.seconds(1)) { await subscribeAndDeliver() }
        #expect(whileLatched == nil, "expected the latch to swallow the message, got \(String(describing: whileLatched))")

        // reopen() clears it.
        await manager.reopen()
        let afterReopen = await boundedly(.seconds(2)) { await subscribeAndDeliver() }
        #expect(afterReopen == true, "manager still discarding after reopen()")
    }

    /// End-to-end sanity: a drain on one client does not disturb a fresh one.
    /// Note this does *not* exercise the `isClosed` latch — each client has its
    /// own manager — it guards the surrounding drain/close path.
    @Test("A drain on one client leaves a fresh client working", .timeLimit(.minutes(1)))
    func subscriptionsWorkAfterDrain() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14232) else { return }
        defer { server.stop() }

        let url = URL(string: "nats://127.0.0.1:\(server.port)")!

        // First lifecycle: connect and drain, which latches isClosed.
        let first = NatsClient {
            $0.servers = [url]
            $0.reconnect = .disabled
        }
        try await first.connect()
        _ = try await first.subscribe("reuse.test")
        try await first.drain()

        // A drained client is closed, so a second connection means a second
        // client — but the manager reset is what this is really checking, via
        // the same code path a reconnect takes.
        let second = NatsClient {
            $0.servers = [url]
            $0.reconnect = .disabled
        }
        defer { Task { await second.close() } }

        try await second.connect()
        let subscription = try await second.subscribe("reuse.test")

        try await second.publish("reuse.test", payload: ByteBuffer(string: "hello"))

        let received = await boundedly(.seconds(5)) { () -> String? in
            for await message in subscription {
                return String(buffer: message.payload)
            }
            return nil
        }

        #expect(received == "hello", "message not delivered after a prior drain: \(String(describing: received))")
    }

    // MARK: - Handshake failures must not brick the client

    /// A TLS handshake failure used to run its teardown through `close()`,
    /// parking the state machine in the terminal `.closed` state — so a server
    /// that requires TLS the client is not configured for permanently bricked
    /// the instance instead of just failing that attempt.
    ///
    /// Same defect `fbf57ab` fixed for cancellation, reached by a different
    /// path and missed at the time because nothing tested a TLS mismatch's
    /// after-effects.
    @Test("A TLS mismatch fails the attempt without closing the client", .timeLimit(.minutes(1)))
    func tlsMismatchLeavesClientRetryable() async throws {
        // Peer advertises tls_required; the client is plain nats:// with TLS
        // off, so it takes the `tlsRequired && !wantsTLS` path.
        let peer = try await StalledPeer.start(.sendTLSInfoThenStall)
        defer { Task { await peer.stop() } }

        var options = NatsClientOptions(servers: [peer.url])
        options.reconnect = .disabled
        options.connectTimeout = .seconds(2)
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        let first = await boundedly(.seconds(5)) {
            await OperationOutcome { try await client.connect() }
        }
        #expect(first?.isFailure == true, "expected the TLS mismatch to fail the connect: \(String(describing: first))")

        let state = await client.state
        #expect(
            state != .closed,
            "a TLS handshake failure must not park the client in the terminal .closed state"
        )

        // And the instance must still be usable: a retry has to be attempted,
        // not rejected out of hand off the `.closed` guard.
        let second = await boundedly(.seconds(5)) {
            await OperationOutcome { try await client.connect() }
        }
        #expect(
            second?.isFailure == true,
            "retry after a TLS failure should be attempted and fail on its own merits: \(String(describing: second))"
        )
        #expect(
            second?.message?.contains("Connection is closed") != true,
            "retry was rejected by the .closed guard — the client was bricked by the first failure"
        )
    }

    // MARK: - close() and the reconnection task

    /// `close()` cancelled `reconnectionTask` without awaiting it. A suspended
    /// attempt could then resume *after* `eventLoopGroup` was nil'd and build a
    /// fresh group that nothing would ever shut down — one leaked group and
    /// thread per occurrence.
    @Test("close() returns promptly while a reconnect is in flight", .timeLimit(.minutes(1)))
    func closeWaitsForReconnectionWithoutHanging() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14233) else { return }

        var options = NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:\(server.port)")!])
        options.reconnect = ReconnectPolicy(enabled: true, maxAttempts: 1000, initialDelay: .milliseconds(50))
        let client = NatsClient(options: options)

        try await client.connect()

        // Drop the server so the client enters its reconnect loop.
        server.stop()
        try await Task.sleep(for: .milliseconds(400))

        let closed = await boundedly(.seconds(10)) {
            await client.close()
            return true
        }

        #expect(closed == true, "close() did not return within 10s while reconnecting")

        let state = await client.state
        #expect(state == .closed)
    }
}
