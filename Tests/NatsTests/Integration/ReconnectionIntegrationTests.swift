// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
import NIOCore
@testable import Nats

/// Integration tests that exercise the automatic reconnection path.
///
/// Unlike the other integration suites these manage their own dedicated
/// `nats-server` process, so the test can drop and restore the connection.
/// They skip gracefully when the `nats-server` binary cannot be located.
@Suite("Reconnection Integration Tests", .serialized)
struct ReconnectionIntegrationTests {

    /// Regression test: after an automatic reconnect, a subscription that was
    /// created *before* the outage must keep receiving messages.
    ///
    /// The bug this guards against sent the resubscribe `SUB` frames before
    /// the NATS handshake completed, so the server discarded them and the
    /// subscription silently went dead after every reconnect.
    @Test("Existing subscriptions keep receiving after a reconnect")
    func resubscribeAfterReconnect() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14228) else {
            return  // nats-server binary unavailable in this environment — skip
        }
        defer { server.stop() }

        let client = NatsClient {
            $0.servers = [URL(string: "nats://127.0.0.1:14228")!]
            $0.reconnect = ReconnectPolicy(
                enabled: true,
                maxAttempts: 200,
                initialDelay: .milliseconds(50),
                maxDelay: .milliseconds(500)
            )
        }
        try await connectWithRetry(client, timeout: .seconds(10))

        // Subscribe *before* the connection drops.
        let subscription = try await client.subscribe("reconnect.subject")

        // Simulate an outage: kill the server, then bring it back on the same
        // port so the client's reconnection loop can succeed.
        server.stop()
        try await Task.sleep(for: .milliseconds(300))
        try server.restart()

        // The client should automatically reconnect and report itself
        // connected again — this also exercises the state-machine fix, since
        // a stuck `.disconnected` state would leave `isConnected` false.
        try await waitUntil(timeout: .seconds(15)) {
            await client.isConnected
        }
        #expect(await client.isConnected, "client did not reconnect")

        // The subscription created before the outage must still deliver
        // messages. Without the resubscribe fix the server has no record of
        // it, so this message would never arrive.
        try await client.publish("reconnect.subject", payload: .from("after-reconnect"))

        let message = try await firstMessage(from: subscription, timeout: .seconds(5))

        // Close the client first so its reconnection loop stops before the
        // dedicated server is torn down by the `defer` above.
        await client.close()

        #expect(
            message?.string == "after-reconnect",
            "subscription stopped receiving messages after reconnect"
        )
    }
}

// MARK: - Test Helpers

/// Connect a client, retrying briefly while a freshly-spawned server starts up.
private func connectWithRetry(_ client: NatsClient, timeout: Duration) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        do {
            try await client.connect()
            return
        } catch {
            if clock.now >= deadline { throw error }
            try await Task.sleep(for: .milliseconds(150))
        }
    }
}

/// Poll `condition` until it is true or the timeout elapses.
private func waitUntil(
    timeout: Duration,
    _ condition: @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(100))
    }
}

/// Return the first message delivered to `subscription`, or `nil` on timeout.
private func firstMessage(
    from subscription: Subscription,
    timeout: Duration
) async throws -> NatsMessage? {
    try await withThrowingTaskGroup(of: NatsMessage?.self) { group in
        group.addTask {
            for await message in subscription {
                return message
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let result = try await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
