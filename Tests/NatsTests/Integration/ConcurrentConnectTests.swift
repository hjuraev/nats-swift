// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
@testable import Nats

/// Load-shaped coverage for the connect handshake.
///
/// The bug these guard against only appears under a burst: a single connect in
/// isolation practically never loses the race, which is why every existing
/// suite passed while a downstream service saw ~20 failures per combined run.
@Suite("Concurrent Connect Tests", .serialized)
struct ConcurrentConnectTests {

    /// Regression: `establishConnection()` installs the channel handler in the
    /// pipeline *before* `bootstrap.connect()` resolves and assigns
    /// `self.channel`. On a fast or loaded connection the server's INFO reached
    /// the actor first, `handleInfo()` tried to write CONNECT, and `write()`
    /// threw off its own `guard let channel` — surfacing to the caller as
    /// `IO error: Connection is closed`.
    ///
    /// It read like the server hanging up on us. It was entirely client-side:
    /// the socket was healthy and the broker logged nothing. Measured at 120
    /// concurrent connects before the fix: 47, 16 and 42 failures across three
    /// runs.
    @Test("A burst of concurrent connects all succeed", .timeLimit(.minutes(2)))
    func burstOfConcurrentConnectsAllSucceed() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14229) else {
            return  // nats-server binary unavailable in this environment — skip
        }
        defer { server.stop() }

        let url = URL(string: "nats://127.0.0.1:\(server.port)")!
        let clientCount = 60

        let failures = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<clientCount {
                group.addTask {
                    let client = NatsClient {
                        $0.servers = [url]
                        $0.reconnect = .disabled
                    }
                    defer { Task { await client.close() } }
                    do {
                        try await client.connect()
                        return nil
                    } catch {
                        return "\(error)"
                    }
                }
            }

            var collected: [String] = []
            for await failure in group {
                if let failure { collected.append(failure) }
            }
            return collected
        }

        #expect(
            failures.isEmpty,
            "\(failures.count)/\(clientCount) concurrent connects failed: \(Set(failures))"
        )
    }
}
