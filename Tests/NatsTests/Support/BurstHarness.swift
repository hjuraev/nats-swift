// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
@testable import Nats

/// Drives N clients through an operation concurrently and collects the failures.
///
/// Races in this client are essentially invisible one connection at a time —
/// `2e6e7f6` (INFO arriving before `self.channel` was assigned) needed ~120
/// concurrent connects to show up at all, while every single-client test in the
/// suite passed. Anything touching connection setup or teardown deserves a run
/// through here.
enum BurstHarness {

    /// Result of one burst.
    struct Outcome: Sendable {
        let total: Int
        let failures: [String]

        var isClean: Bool { failures.isEmpty }

        /// Failure messages grouped by text, most frequent first.
        var summary: String {
            let counts = Dictionary(grouping: failures, by: { $0 }).mapValues(\.count)
            return counts
                .sorted { $0.value > $1.value }
                .map { "\($0.value)x \($0.key)" }
                .joined(separator: "; ")
        }
    }

    /// Run `body` on `count` freshly-built clients at once.
    ///
    /// Each client is closed afterwards regardless of outcome, so a burst does
    /// not leak event-loop groups into the rest of the suite.
    static func run(
        count: Int,
        against url: URL,
        configure: @Sendable @escaping (inout NatsClientOptions) -> Void = { _ in },
        body: @Sendable @escaping (NatsClient) async throws -> Void
    ) async -> Outcome {
        let failures = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<count {
                group.addTask {
                    var options = NatsClientOptions(servers: [url])
                    options.reconnect = .disabled
                    configure(&options)

                    let client = NatsClient(options: options)
                    defer { Task { await client.close() } }

                    do {
                        try await body(client)
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

        return Outcome(total: count, failures: failures)
    }
}
