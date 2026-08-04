// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
import NIOCore
@testable import Nats

/// `fetch(batch:maxWait:)` must always return — and must not return early.
///
/// **What these tests do and do not establish.** Both properties below hold
/// today, and both held *before* the client-side expiry task was added: with a
/// live broker the 408 reply ends the collection loop, and when the broker
/// vanishes the loop ends through connection teardown. So neither is a
/// regression test for that task.
///
/// The case it exists for is the one that could not be staged here: a pull
/// request lost in a reconnect window, where the connection stays up and no 408
/// is ever coming. The deadline check sits inside `for await msg in
/// subscription`, so it is only evaluated once a message has arrived — nothing
/// ends an idle loop. That symptom is first-hand downstream (NexusMessaging
/// carries a fetch watchdog written specifically because "the SDK enforces no
/// client-side deadline while idle"), which is why the guard is worth keeping
/// even unproven here.
///
/// `KeyValueBucket.keys()`, `history()` and `purgeDeletes()` all loop on
/// `fetch` and inherit whatever it does.
@Suite("Fetch Deadline Tests", .serialized)
struct FetchDeadlineTests {

    /// Property: a fetch in flight when the broker disappears must not hang.
    /// Satisfied today by connection teardown rather than by the deadline —
    /// verified by removing the deadline task, after which this still passes.
    @Test("fetch does not hang when the broker goes away mid-pull", .timeLimit(.minutes(2)))
    func fetchHonoursDeadlineWhenNoReplyIsComing() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14240, jetStream: true) else {
            return  // nats-server unavailable — skip
        }
        defer { server.stopAndCleanUp() }

        var options = NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:\(server.port)")!])
        // Reconnect off: the connection stays down, so nothing will ever deliver
        // a 408 and only a client-side deadline can end the fetch.
        options.reconnect = .disabled
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        try await client.connect()
        let js = try await client.jetStream()

        let streamName = "TEST_FETCH_DEADLINE_\(UUID().uuidString.prefix(8))"
        let stream = try await js.createStream(StreamConfig(
            name: streamName,
            subjects: ["\(streamName).>"]
        ))
        let consumer = try await stream.createConsumer(config: ConsumerConfig(
            name: "deadline-probe",
            deliverPolicy: .all,
            ackPolicy: .explicit
        ))

        // Start a fetch with a long deadline and let the pull request actually
        // reach the broker before taking it away. Without the pause the fetch
        // fails fast at its own publish ("Not connected") and the test would
        // pass for entirely the wrong reason.
        let finished = ResultBox<Int>()
        let started = ContinuousClock().now
        let fetcher = Task {
            let messages = try? await consumer.fetch(batch: 10, maxWait: .seconds(3))
            finished.set(messages?.count ?? -1)
        }
        defer { fetcher.cancel() }

        try await Task.sleep(for: .milliseconds(300))
        #expect(finished.value == nil, "precondition: the fetch should still be waiting on the broker")

        server.stop()

        // Nothing can deliver a 408 now. Only the client-side deadline can end
        // this, and it should do so at roughly the 3s mark.
        let limit = ContinuousClock().now.advanced(by: .seconds(12))
        while ContinuousClock().now < limit && finished.value == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = ContinuousClock().now - started

        guard finished.value != nil else {
            Issue.record("fetch never returned after the broker vanished — its deadline is unenforced")
            return
        }
        #expect(elapsed < .seconds(10), "fetch took \(elapsed) against a 3s maxWait")
    }

    /// The ordinary path must keep working: a live broker's 408 should still end
    /// the fetch promptly, and the client deadline must not cut it short.
    @Test("fetch still returns an empty batch against a live idle consumer", .timeLimit(.minutes(2)))
    func fetchStillWorksAgainstLiveBroker() async throws {
        guard let server = NatsServerProcess.startIfAvailable(port: 14241, jetStream: true) else {
            return
        }
        defer { server.stopAndCleanUp() }

        var options = NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:\(server.port)")!])
        options.reconnect = .disabled
        let client = NatsClient(options: options)
        defer { Task { await client.close() } }

        try await client.connect()
        let js = try await client.jetStream()

        let streamName = "TEST_FETCH_LIVE_\(UUID().uuidString.prefix(8))"
        let stream = try await js.createStream(StreamConfig(
            name: streamName,
            subjects: ["\(streamName).>"]
        ))
        let consumer = try await stream.createConsumer(config: ConsumerConfig(
            name: "live-probe",
            deliverPolicy: .all,
            ackPolicy: .explicit
        ))

        let count = await boundedly(.seconds(20)) { () -> Int in
            let messages = try? await consumer.fetch(batch: 10, maxWait: .milliseconds(500))
            return messages?.count ?? -1
        }

        #expect(count == 0, "expected an empty batch from an idle consumer, got \(String(describing: count))")
    }
}
