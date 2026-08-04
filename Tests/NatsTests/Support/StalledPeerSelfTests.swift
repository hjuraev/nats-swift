// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
import NIOCore
@testable import Nats

/// Self-tests for the test fixtures.
///
/// A fixture nothing exercises rots silently, and a *broken* stall fixture is
/// worse than none: it makes the tests that depend on it pass for the wrong
/// reason. These assert each behaviour actually misbehaves as advertised.
@Suite("Stalled Peer Fixture Tests", .serialized)
struct StalledPeerSelfTests {

    @Test("A silent peer leaves connect unresolved until its deadline", .timeLimit(.minutes(1)))
    func silentPeerStallsConnect() async throws {
        let peer = try await StalledPeer.start(.silent)
        defer { Task { await peer.stop() } }

        var options = NatsClientOptions(servers: [peer.url])
        options.reconnect = .disabled
        options.connectTimeout = .milliseconds(300)
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        let start = ContinuousClock().now
        let outcome = await boundedly { await OperationOutcome { try await client.connect() } }

        guard let outcome else {
            Issue.record("connect never returned — the client is not bounded")
            return
        }
        #expect(outcome.isFailure, "a silent peer must not produce a successful connect")

        // It must have actually waited, not failed instantly for some other reason.
        #expect(ContinuousClock().now - start >= .milliseconds(250))
    }

    @Test("A peer that sends INFO completes the handshake, then stalls bulk writes", .timeLimit(.minutes(1)))
    func infoFrameIsAcceptedAndBulkWritesStall() async throws {
        let peer = try await StalledPeer.start(.sendInfoThenStopReading)
        defer { Task { await peer.stop() } }

        var options = NatsClientOptions(servers: [peer.url])
        options.reconnect = .disabled
        options.connectTimeout = .seconds(2)
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        // The handshake *succeeds* here, and that is the point: it proves the
        // fixture's INFO frame is well-formed and accepted. NATS does not
        // require a server response to CONNECT, and CONNECT is small enough to
        // fit the socket buffer, so a peer that never reads still yields a live
        // connection.
        let connected = await boundedly { await OperationOutcome { try await client.connect() } }
        #expect(
            connected == .succeeded,
            "INFO frame was not accepted, so anything built on this fixture tests the wrong thing: \(String(describing: connected))"
        )

        // Back-pressure only bites once the peer's receive window closes, which
        // takes more than one small frame.
        let payload: ByteBuffer = {
            var buffer = ByteBuffer()
            buffer.writeRepeatingByte(0x41, count: 1024 * 1024)
            return buffer
        }()

        let bulk = await boundedly(.seconds(3)) {
            await OperationOutcome {
                for _ in 0..<64 {
                    try await client.publish("stall.test", payload: payload)
                }
            }
        }

        // nil = still stalled (today's behaviour — writes are unbounded, plan
        // item 3.2). A bounded failure is the intended end state. Either shows
        // the fixture creates real back-pressure; a fast success would mean it
        // does not.
        #expect(
            bulk?.isFailure ?? true,
            "64 MB written to a peer that never reads should not succeed quickly: \(String(describing: bulk))"
        )
    }

    @Test("A non-reading peer does not drain what the client sends", .timeLimit(.minutes(1)))
    func nonReadingPeerAcceptsButNeverReads() async throws {
        let peer = try await StalledPeer.start(.stopReading)
        defer { Task { await peer.stop() } }

        // The peer must still accept the TCP connection — the fixture is only
        // useful if the client gets far enough to be stuck.
        var options = NatsClientOptions(servers: [peer.url])
        options.reconnect = .disabled
        options.connectTimeout = .milliseconds(300)
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        let outcome = await boundedly { await OperationOutcome { try await client.connect() } }

        guard let outcome, let message = outcome.message else {
            Issue.record("expected connect to fail against a non-reading peer")
            return
        }
        // Reaching a timeout (not "connection refused") proves the socket was accepted.
        #expect(
            !message.lowercased().contains("refused"),
            "peer refused the connection instead of accepting and stalling: \(message)"
        )
    }

    @Test("A TLS-advertising peer that never handshakes does not connect", .timeLimit(.minutes(1)))
    func tlsStallingPeerDoesNotConnect() async throws {
        let peer = try await StalledPeer.start(.sendTLSInfoThenStall)
        defer { Task { await peer.stop() } }

        var options = NatsClientOptions(servers: [peer.url])
        options.reconnect = .disabled
        options.connectTimeout = .milliseconds(400)
        options.tls.certificateVerification = .none
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        let outcome = await boundedly(.seconds(8)) {
            await OperationOutcome { try await client.connect() }
        }

        // Documents today's behaviour. Once the TLS handshake deadline lands
        // (plan phase 3.4) this should be a bounded failure every time; if it
        // returns nil here, the client hung, which is the defect being tracked.
        if let outcome {
            #expect(outcome.isFailure, "a peer that never completes TLS must not yield a live connection")
        } else {
            Issue.record("connect against a stalling TLS peer did not return within 8s — unbounded TLS handshake (plan item 3.4)")
        }
    }
}
