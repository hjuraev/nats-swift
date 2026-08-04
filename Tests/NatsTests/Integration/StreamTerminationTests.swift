// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
import NIOCore
@testable import Nats

/// Coverage for streams actually ending when there is nothing more coming.
///
/// A consumer suspended forever on `for await` is as broken as a hang, and
/// harder to spot: the subscription looks alive, the client reports no error,
/// and the process simply stops making progress. Silence is the worst possible
/// report.
@Suite("Stream Termination Tests", .serialized)
struct StreamTerminationTests {

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ v: String) { lock.lock(); if value == nil { value = v }; lock.unlock() }
        var current: String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func waitFor(_ outcome: Outcome, upTo limit: Duration) async throws -> String? {
        let deadline = ContinuousClock().now.advanced(by: limit)
        while ContinuousClock().now < deadline && outcome.current == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        return outcome.current
    }

    /// With reconnection disabled a dropped connection is permanent, so a
    /// subscription can never deliver again. It used to stay open regardless,
    /// leaving consumers iterating something already dead.
    @Test("Subscriptions end when the connection drops for good", .timeLimit(.minutes(2)))
    func subscriptionsEndOnPermanentDisconnect() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14243) else { return }
        defer { server.stop() }

        var options = NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:\(server.port)")!])
        options.reconnect = .disabled
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        try await client.connect()
        let subscription = try await client.subscribe("termination.test")

        let outcome = Outcome()
        let consumer = Task {
            var count = 0
            for await _ in subscription { count += 1 }
            outcome.set("ended after \(count)")
        }
        defer { consumer.cancel() }

        try await Task.sleep(for: .milliseconds(300))
        #expect(outcome.current == nil, "precondition: the consumer should still be iterating")

        server.stop()

        let result = try await waitFor(outcome, upTo: .seconds(10))
        #expect(result != nil, "consumer is still iterating a subscription that can never deliver again")
    }

    /// The opposite guard: when a reconnect *is* coming, subscriptions are
    /// restored by `resubscribeAll`, so finishing them would destroy the very
    /// thing being restored.
    @Test("Subscriptions survive a drop when reconnection is enabled", .timeLimit(.minutes(2)))
    func subscriptionsSurviveWhenReconnecting() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14244) else { return }
        defer { server.stop() }

        var options = NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:\(server.port)")!])
        options.reconnect = ReconnectPolicy(enabled: true, maxAttempts: 1000, initialDelay: .milliseconds(50))
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        try await client.connect()
        let subscription = try await client.subscribe("termination.reconnect")

        // One consumer only — an AsyncStream has a single iterator, so a second
        // `for await` elsewhere would silently steal the messages this one is
        // counting.
        let outcome = Outcome()
        let received = Counter()
        let consumer = Task {
            var count = 0
            for await _ in subscription {
                count += 1
                received.increment()
            }
            outcome.set("ended after \(count)")
        }
        defer { consumer.cancel() }

        // Drop and restore the broker; the subscription must ride through it.
        server.stop()
        try await Task.sleep(for: .milliseconds(400))
        try server.restart()

        // Give the client time to reconnect and resubscribe.
        try await Task.sleep(for: .seconds(2))

        #expect(
            outcome.current == nil,
            "subscription was finished during a reconnect, destroying what resubscribeAll restores"
        )

        // And it must still be delivering.
        try await client.publish("termination.reconnect", payload: ByteBuffer(string: "hi"))

        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while ContinuousClock().now < deadline && received.value == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(received.value > 0, "subscription stopped delivering after a reconnect")
    }

    /// `KeyValueWatcher.stop()` deleted the consumer and left the stream open,
    /// so a caller who stopped a watcher stayed suspended on it.
    @Test("A stopped KeyValue watcher ends its stream", .timeLimit(.minutes(2)))
    func stoppedWatcherEndsItsStream() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14245, jetStream: true) else { return }
        defer { server.stopAndCleanUp() }

        var options = NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:\(server.port)")!])
        options.reconnect = .disabled
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        try await client.connect()
        let js = try await client.jetStream()

        let bucketName = "WATCH_\(UUID().uuidString.prefix(6))"
        let bucket = try await js.createKeyValue(KeyValueConfig(bucket: bucketName))
        let watcher = try await bucket.watch("**")

        let outcome = Outcome()
        let consumer = Task {
            var count = 0
            do {
                for try await _ in watcher { count += 1 }
                outcome.set("ended after \(count)")
            } catch {
                outcome.set("ended with error after \(count)")
            }
        }
        defer { consumer.cancel() }

        // Let it deliver its initial sentinel and settle into watching.
        try await Task.sleep(for: .milliseconds(500))
        #expect(outcome.current == nil, "precondition: the watcher should still be iterating")

        try await watcher.stop()

        let result = try await waitFor(outcome, upTo: .seconds(10))
        #expect(result != nil, "a stopped watcher left its consumer suspended")
    }
}
