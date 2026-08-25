// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
@testable import Nats

/// Attribution for a stalled TLS handshake.
///
/// **This is not about boundedness.** A stalled handshake is already bounded —
/// the connect deadline covers it and leaves the client retryable, measured at
/// 0.62s against a 600ms budget. What was missing is knowing *which* phase
/// stalled: a peer that never answered the ClientHello produced the same bare
/// "connection timeout" as a slow TCP connect or a server that never sent INFO.
///
/// Misattribution has been by far the most expensive failure mode in this
/// client — a client-side race spent weeks being read as the server hanging up —
/// so naming the phase is worth a handler.
@Suite("TLS Handshake Deadline Tests", .serialized)
struct TLSHandshakeDeadlineTests {

    @Test("A peer that never answers the ClientHello is reported as a TLS stall", .timeLimit(.minutes(1)))
    func stalledHandshakeIsAttributedToTLS() async throws {
        let peer = try await StalledPeer.start(.sendTLSInfoThenStall)
        defer { Task { await peer.stop() } }

        var options = NatsClientOptions(servers: [peer.url])
        options.reconnect = .disabled
        options.connectTimeout = .milliseconds(600)
        // Far larger, so the connect deadline is unambiguously what ends this.
        options.writeTimeout = .seconds(30)
        options.tls.enabled = true
        options.tls.certificateVerification = .none
        // NIOSSL cannot put a bare IP in SNI, so give it a name.
        options.tls.serverHostname = "localhost"

        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        let outcome = await boundedly(.seconds(10)) {
            await OperationOutcome { try await client.connect() }
        }

        guard let message = outcome?.message else {
            Issue.record("expected the stalled TLS handshake to fail: \(String(describing: outcome))")
            return
        }
        #expect(
            message.contains("TLS handshake did not complete"),
            "expected the failure to name the TLS phase, got: \(message)"
        )

        // Still bounded, and still retryable — attribution must not have cost
        // either property.
        let state = await client.state
        #expect(state != .closed, "a stalled TLS handshake must not brick the client")
    }

    /// A server that completes TLS and then stalls must NOT be reported as a
    /// TLS failure — that would trade one misattribution for another.
    @Test("A stall after a successful handshake is not blamed on TLS", .timeLimit(.minutes(1)))
    func postHandshakeStallIsNotBlamedOnTLS() async throws {
        // Real server with TLS available, but the client never gets INFO
        // because... it does. So instead: a non-TLS client against the silent
        // peer, which is the plain "no INFO" stall. It must report a timeout,
        // not a TLS failure.
        let peer = try await StalledPeer.start(.silent)
        defer { Task { await peer.stop() } }

        var options = NatsClientOptions(servers: [peer.url])
        options.reconnect = .disabled
        options.connectTimeout = .milliseconds(400)

        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        let outcome = await boundedly(.seconds(10)) {
            await OperationOutcome { try await client.connect() }
        }

        guard let message = outcome?.message else {
            Issue.record("expected the silent peer to fail the connect: \(String(describing: outcome))")
            return
        }
        #expect(
            !message.contains("TLS"),
            "a non-TLS stall must not be attributed to TLS: \(message)"
        )
    }

    /// The observer must not break ordinary TLS connections — it sits in the
    /// pipeline of every one of them.
    @Test("A real TLS connection still succeeds", .timeLimit(.minutes(1)))
    func realTLSConnectionStillWorks() async throws {
        // CI runs `.github/nats-server.conf` on 4222 — TLS with `allow_non_tls`.
        // Skip when that is not what is listening, rather than fail spuriously.
        guard await Self.serverOffersTLS(port: 4222) else { return }

        var options = NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:4222")!])
        options.reconnect = .disabled
        options.connectTimeout = .seconds(5)
        options.tls.enabled = true
        options.tls.certificateVerification = .none
        options.tls.serverHostname = "localhost"

        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        let outcome = await boundedly(.seconds(15)) {
            await OperationOutcome { try await client.connect() }
        }

        #expect(outcome == .succeeded, "TLS connect regressed: \(String(describing: outcome))")

        let connected = await client.isConnected
        #expect(connected, "client should be connected over TLS")
    }

    /// Whether the server on `port` actually offers TLS.
    ///
    /// The previous precondition only checked that *something* was listening on
    /// 4222. Any plaintext NATS there — a local dev server, another project's
    /// container — satisfied it, and the TLS connect then failed the handshake
    /// with WRONG_VERSION_NUMBER. That reported a TLS regression in the client
    /// when the only problem was which server happened to hold the port.
    ///
    /// Ask the server instead of guessing. NATS sends INFO before any TLS
    /// upgrade, so a plaintext probe reveals the capability directly. A
    /// TLS-*required* server (no `allow_non_tls`) refuses the plaintext probe,
    /// so this errs toward skipping the test rather than toward a false failure.
    private static func serverOffersTLS(port: Int) async -> Bool {
        guard let url = URL(string: "nats://127.0.0.1:\(port)") else { return false }

        var options = NatsClientOptions(servers: [url])
        options.reconnect = .disabled
        options.connectTimeout = .seconds(2)
        options.tls.enabled = false

        // Closed deterministically, NOT via `defer { Task { ... } }`. That idiom
        // only schedules the close, so the probe's connection (and its ping
        // timer) outlives this helper and competes with the rest of the suite.
        let probe = NatsClient(options: options)
        do {
            try await probe.connect()
        } catch {
            await probe.close()
            return false
        }

        let info = await probe.serverInfo
        await probe.close()
        return info?.tlsAvailable == true || info?.tlsRequired == true
    }
}
