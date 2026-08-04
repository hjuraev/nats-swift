// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
import NIOCore
import NIOPosix
@testable import Nats

/// Coverage for `NatsClientOptions.eventLoopGroup`.
///
/// The ownership rule is the whole point: getting it backwards shuts down a
/// group other clients are still using, which is a worse failure than the
/// per-client groups it replaces.
@Suite("Shared EventLoopGroup Tests", .serialized)
struct SharedEventLoopGroupTests {

    /// Confirms a group is still alive by doing real work on it.
    ///
    /// Only ever call this on a group expected to be *live*. Probing a
    /// shut-down `MultiThreadedEventLoopGroup` does not reliably throw — the
    /// submitted work can simply never run — so a "is it dead?" check written
    /// this way hangs instead of failing. Deadness is asserted structurally
    /// below instead.
    private func isUsable(_ group: EventLoopGroup) async -> Bool {
        let probe = await boundedly(.seconds(3)) { () -> Bool in
            do {
                return try await group.next().submit { true }.get()
            } catch {
                return false
            }
        }
        return probe ?? false
    }

    @Test("close() does not shut down an injected group", .timeLimit(.minutes(1)))
    func injectedGroupSurvivesClose() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14234) else { return }
        defer { server.stop() }

        let shared = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await shared.shutdownGracefully() } }

        var options = NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:\(server.port)")!])
        options.reconnect = .disabled
        options.eventLoopGroup = shared

        let client = NatsClient(options: options)
        try await client.connect()
        await client.close()

        let usable = await isUsable(shared)
        #expect(usable, "close() shut down a group it does not own")

        // The client must also keep referencing it rather than dropping it on
        // the floor, so a later connect on this instance reuses the caller's
        // group instead of quietly building its own.
        let retained = await client.eventLoopGroupForTesting
        #expect(retained != nil, "client discarded the injected group on close()")
    }

    @Test("An owned group is shut down by close()", .timeLimit(.minutes(1)))
    func ownedGroupIsShutDownByClose() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14235) else { return }
        defer { server.stop() }

        var options = NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:\(server.port)")!])
        options.reconnect = .disabled
        // No injected group: the client creates and owns one.

        let client = NatsClient(options: options)
        try await client.connect()

        // Reach in to observe the group the client built for itself, so the
        // teardown can actually be asserted rather than assumed.
        let owned = await client.eventLoopGroupForTesting
        #expect(owned != nil, "client did not create a group of its own")

        await client.close()

        // Asserted structurally: close() clears the reference only on the
        // owned branch, so a nil here proves the shutdown path ran. Probing the
        // group directly would hang rather than report (see isUsable).
        let afterClose = await client.eventLoopGroupForTesting
        #expect(afterClose == nil, "close() left its own group in place — the leak this option is meant to avoid")
    }

    @Test("Many clients share one injected group", .timeLimit(.minutes(2)))
    func manyClientsShareOneGroup() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14236) else { return }
        defer { server.stop() }

        let shared = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await shared.shutdownGracefully() } }

        // The actual win: 40 clients on one group. Also re-runs the burst that
        // exposed the INFO race, now with a shared loop where every connect is
        // contending for the same threads.
        let outcome = await BurstHarness.run(
            count: 40,
            against: URL(string: "nats://127.0.0.1:\(server.port)")!,
            configure: { $0.eventLoopGroup = shared }
        ) { client in
            try await client.connect()
        }

        #expect(
            outcome.isClean,
            "\(outcome.failures.count)/\(outcome.total) shared-group connects failed: \(outcome.summary)"
        )

        let usable = await isUsable(shared)
        #expect(usable, "the shared group did not survive 40 clients closing")
    }
}
