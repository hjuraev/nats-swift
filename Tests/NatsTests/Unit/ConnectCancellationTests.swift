// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Nats

@Suite("Connect Cancellation Tests")
struct ConnectCancellationTests {

    private func makeStalledClient(_ peer: StalledPeer) -> NatsClient {
        NatsClient {
            $0.servers = [peer.url]
            $0.reconnect = .disabled
            // Long enough that the client's own deadline cannot be what ends
            // these waits — cancellation has to be doing the work.
            $0.connectTimeout = .seconds(3600)
        }
    }

    /// Regression: `connect()` used to wait on a bare `CheckedContinuation`
    /// with no cancellation handler. Cancelling it set the cancelled flag and
    /// then waited forever, so any caller racing it against a deadline (Nexus
    /// boot does exactly that) was left holding a task that could never finish.
    @Test("Cancelling a stalled connect unwinds instead of hanging", .timeLimit(.minutes(1)))
    func cancelledConnectUnwinds() async throws {
        let peer = try await StalledPeer.start(.silent)
        defer { Task { await peer.stop() } }

        let client = makeStalledClient(peer)
        let outcome = ResultBox<OperationOutcome>()

        let connectTask = Task {
            outcome.set(await OperationOutcome { try await client.connect() })
        }

        // Let it get past the TCP connect and park on the handshake wait.
        try await Task.sleep(for: .milliseconds(300))
        #expect(outcome.value == nil, "connect should still be waiting on the handshake")

        connectTask.cancel()

        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while ContinuousClock().now < deadline && outcome.value == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        guard let result = outcome.value else {
            Issue.record("cancelled connect did not unwind within 5s — it is hung")
            return
        }
        #expect(result.isFailure, "expected a cancelled connect to throw, got \(result)")
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
        let peer = try await StalledPeer.start(.silent)
        defer { Task { await peer.stop() } }

        let client = makeStalledClient(peer)
        let outcome = ResultBox<OperationOutcome>()

        let connectTask = Task {
            outcome.set(await OperationOutcome { try await client.connect() })
        }

        try await Task.sleep(for: .milliseconds(300))
        connectTask.cancel()

        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while ContinuousClock().now < deadline && outcome.value == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard outcome.value != nil else {
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
        // rejected out of hand. It still cannot succeed against a silent peer,
        // so it should reach the handshake wait and stay there rather than
        // failing instantly off the `.closed` guard.
        let retry = await boundedly(.seconds(1)) {
            await OperationOutcome { try await client.connect() }
        }
        #expect(
            retry == nil,
            "retry after a cancelled connect should reach the handshake wait, not fail immediately: \(String(describing: retry))"
        )
    }
}
