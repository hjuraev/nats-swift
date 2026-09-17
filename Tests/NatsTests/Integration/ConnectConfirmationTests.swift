// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
import NIOCore
@testable import Nats

/// A connect or reconnect succeeds only when the server has accepted CONNECT
/// (nats#1).
///
/// Clients built before 230b209 marked a reconnect successful once TCP was up.
/// A server that then rejected CONNECT closed the socket while the client was
/// not "active", so nothing reconnected it again: services stayed up for hours
/// with no connection and no subscriptions. The loop was fixed; these pin the
/// behaviour down, along with the confirmation the fix relied on — which used
/// to be "no -ERR within 250 ms".
@Suite("Connect Confirmation Tests", .serialized)
struct ConnectConfirmationTests {

    @Test("A client rejected during reconnect keeps retrying and recovers once accepted", .timeLimit(.minutes(2)))
    func authRejectionDuringReconnect() async throws {
        let accepted = ["--user", "good", "--pass", "secret"]
        guard let server = NatsServerProcess.startIfAvailable(port: 14246, arguments: accepted) else {
            return  // nats-server unavailable — skip
        }
        defer { server.stopAndCleanUp() }

        var options = NatsClientOptions(servers: [URL(string: "nats://good:secret@127.0.0.1:14246")!])
        options.reconnect = ReconnectPolicy(maxAttempts: -1, initialDelay: .milliseconds(50), maxDelay: .milliseconds(250))
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        try await client.connect()
        let subscription = try await client.subscribe("auth.recover")

        // The server comes back refusing these credentials, as a server that
        // restarts before its accounts are loaded does.
        server.stop()
        try server.restart(arguments: ["--user", "other", "--pass", "nope"])

        let rejected = await boundedly(.seconds(15)) { () -> Bool in
            while await client.handshakeRejectionsForTesting < 2 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return true
        }
        #expect(rejected == true, "the reconnecting client was never rejected — the scenario did not happen")
        #expect(await client.isConnected == false, "a rejected CONNECT was reported as connected")
        #expect(await client.state != .closed, "the client gave up after a rejection")

        server.stop()
        try server.restart(arguments: accepted)

        let recovered = await boundedly(.seconds(15)) { () -> Bool in
            while !(await client.isConnected) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return true
        }
        #expect(recovered == true, "the client stayed disconnected after the server accepted it again")

        // Subscriptions from before the outage work again.
        let publisher = NatsClient(options: NatsClientOptions(servers: [URL(string: "nats://good:secret@127.0.0.1:14246")!]))
        try await publisher.connect()
        defer { Task { await publisher.close() } }

        let received = await boundedly(.seconds(10)) { () -> Bool in
            let pump = Task {
                while !Task.isCancelled {
                    try? await publisher.publish("auth.recover", payload: ByteBuffer(string: "x"))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { pump.cancel() }
            for await _ in subscription { return true }
            return false
        }
        #expect(received == true, "the subscription created before the outage no longer receives")
    }

    @Test("A rejection arriving later than 250 ms still fails the connect", .timeLimit(.minutes(1)))
    func lateRejectionFailsConnect() async throws {
        let peer = try await StalledPeer.start(.rejectConnect(after: .milliseconds(600)))
        defer { Task { await peer.stop() } }

        var options = NatsClientOptions(servers: [peer.url])
        options.reconnect = .disabled
        options.connectTimeout = .seconds(5)
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        let outcome = await boundedly(.seconds(10)) {
            await OperationOutcome { try await client.connect() }
        }

        guard let message = outcome?.message else {
            Issue.record("connect succeeded against a server that rejected it: \(String(describing: outcome))")
            return
        }
        #expect(message.contains("Authorization Violation"), "expected the rejection, got: \(message)")
        #expect(await client.isConnected == false)
        #expect(await client.state != .closed, "a rejected connect must leave the client retryable")
    }

    @Test("Connect completes on the server's PONG, without a fixed wait", .timeLimit(.minutes(1)))
    func connectDoesNotWaitAFixedWindow() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14247) else { return }
        defer { server.stop() }

        var options = NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:14247")!])
        options.reconnect = .disabled
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        let started = ContinuousClock.now
        try await client.connect()
        let elapsed = ContinuousClock.now - started

        #expect(await client.isConnected)
        // The old confirmation slept 250 ms on every connect. Generous against
        // a slow machine, still well under that.
        #expect(elapsed < .milliseconds(200), "connect took \(elapsed)")
    }
}
