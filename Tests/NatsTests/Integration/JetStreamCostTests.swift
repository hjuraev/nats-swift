// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
import NIOCore
@testable import Nats

/// Coverage for the client-side costs and correctness gaps on large JetStream
/// workloads (nats#2): pull fetches, byte-bounded pulls, bucket listings,
/// tombstone purges, watch resume, time-based stream purges, and the ordered,
/// batched connection paths underneath them.
///
/// Each test starts its own `nats-server` on a dedicated port and skips when
/// the binary is unavailable.
@Suite("JetStream Cost Tests", .serialized)
struct JetStreamCostTests {

    // MARK: - Harness

    private struct Harness: @unchecked Sendable {
        let server: NatsServerProcess
        let client: NatsClient
        let js: JetStreamContext

        func tearDown() async {
            await client.close()
            server.stopAndCleanUp()
        }
    }

    private func harness(port: Int) async throws -> Harness? {
        guard let server = NatsServerProcess.startIfAvailable(port: port, jetStream: true) else {
            return nil
        }
        var options = NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:\(port)")!])
        options.reconnect = .disabled
        let client = NatsClient(options: options)
        do {
            try await client.connect()
            let js = try await client.jetStream()
            return Harness(server: server, client: client, js: js)
        } catch {
            await client.close()
            server.stopAndCleanUp()
            throw error
        }
    }

    private func stream(_ js: JetStreamContext, _ name: String) async throws -> Nats.Stream {
        try await js.createStream(StreamConfig(name: name, subjects: ["\(name).>"]))
    }

    private func publish(_ js: JetStreamContext, _ subject: String, count: Int, size: Int = 8) async throws {
        var payload = ByteBuffer()
        payload.writeRepeatingByte(0x61, count: size)
        for _ in 0..<count {
            _ = try await js.publish(subject, payload: payload)
        }
    }

    // MARK: - Stream.purge(olderThan:)

    @Test("purge(olderThan:) removes only messages older than the threshold", .timeLimit(.minutes(1)))
    func purgeOlderThanKeepsNewerMessages() async throws {
        guard let h = try await harness(port: 14260) else { return }
        defer { Task { await h.tearDown() } }

        let stream = try await stream(h.js, "PURGE_AGE")
        try await publish(h.js, "PURGE_AGE.old", count: 3)
        try await Task.sleep(for: .milliseconds(1500))
        try await publish(h.js, "PURGE_AGE.new", count: 2)

        let response = try await stream.purge(olderThan: .seconds(1))
        #expect(response.purged == 3, "expected only the 3 old messages purged, got \(response.purged)")

        try await stream.refresh()
        let remaining = await stream.info.state.messages
        #expect(remaining == 2, "the 2 recent messages must survive, \(remaining) left")
    }

    @Test("purge(olderThan:) on a stream of recent messages purges nothing", .timeLimit(.minutes(1)))
    func purgeOlderThanOnFreshStreamIsANoOp() async throws {
        guard let h = try await harness(port: 14261) else { return }
        defer { Task { await h.tearDown() } }

        let stream = try await stream(h.js, "PURGE_FRESH")
        try await publish(h.js, "PURGE_FRESH.a", count: 5)

        let response = try await stream.purge(olderThan: .seconds(3600))
        #expect(response.purged == 0)
        try await stream.refresh()
        #expect(await stream.info.state.messages == 5)
    }

    @Test("purge(olderThan:) works on a work-queue stream with a consumer", .timeLimit(.minutes(1)))
    func purgeOlderThanOnWorkQueue() async throws {
        guard let h = try await harness(port: 14279) else { return }
        defer { Task { await h.tearDown() } }

        // Before 2.11 the cutoff is resolved through a consumer, which a
        // work-queue stream with an unfiltered consumer refuses (documented).
        let version = (await h.client.serverInfo?.version ?? "0").split(separator: ".").compactMap { Int($0) }
        guard version.count >= 2, (version[0], version[1]) >= (2, 11) else { return }

        let stream = try await h.js.createStream(StreamConfig(
            name: "PURGE_WQ", subjects: ["PURGE_WQ.>"], retention: .workqueue
        ))
        _ = try await stream.createConsumer(config: ConsumerConfig(name: "worker", ackPolicy: .explicit))
        try await publish(h.js, "PURGE_WQ.old", count: 3)
        try await Task.sleep(for: .milliseconds(1500))
        try await publish(h.js, "PURGE_WQ.new", count: 2)

        let response = try await stream.purge(olderThan: .seconds(1))
        #expect(response.purged == 3)
        try await stream.refresh()
        #expect(await stream.info.state.messages == 2)
    }

    // MARK: - Fetch: one inbox per consumer

    @Test("Repeated fetches reuse one inbox subscription", .timeLimit(.minutes(2)))
    func fetchesReuseOneSubscription() async throws {
        guard let h = try await harness(port: 14262) else { return }
        defer { Task { await h.tearDown() } }

        let stream = try await stream(h.js, "FETCH_SUB")
        try await publish(h.js, "FETCH_SUB.x", count: 2000)
        let consumer = try await stream.createConsumer(config: ConsumerConfig(name: "reuse", ackPolicy: .none))

        _ = try await consumer.fetch(batch: 1, maxWait: .seconds(2))
        let afterFirst = await h.client.subscriptionCountForTesting

        var received = 1
        for _ in 1..<2000 {
            received += try await consumer.fetch(batch: 1, maxWait: .seconds(2)).count
        }
        let afterAll = await h.client.subscriptionCountForTesting

        #expect(received == 2000)
        #expect(afterAll == afterFirst, "fetches added subscriptions: \(afterFirst) after one fetch, \(afterAll) after 2000")
    }

    @Test("A stale status from an earlier pull does not end the current one", .timeLimit(.minutes(1)))
    func staleStatusIsIgnored() async throws {
        guard let h = try await harness(port: 14263) else { return }
        defer { Task { await h.tearDown() } }

        let stream = try await stream(h.js, "FETCH_STALE")
        let consumer = try await stream.createConsumer(config: ConsumerConfig(
            name: "stale", deliverPolicy: .new, ackPolicy: .none
        ))
        let name = await consumer.name
        let inbox = try await PullInbox.open(client: h.client)
        let subject = h.js.consumerNextSubject(stream: "FETCH_STALE", consumer: name)

        // Pull 1 expires on the server after 100ms; its 408 arrives while pull 2 waits.
        let first = inbox.beginPull(wanted: 1)
        try await h.client.publish(subject, payload: h.js.encode(NextMessageRequest(batch: 1, expires: 100_000_000)), reply: first)
        _ = inbox.endPull()

        let second = inbox.beginPull(wanted: 1)
        try await h.client.publish(subject, payload: h.js.encode(NextMessageRequest(batch: 1, expires: 3_000_000_000)), reply: second)

        let publisher = Task {
            try await Task.sleep(for: .milliseconds(400))
            _ = try await h.js.publish("FETCH_STALE.x", payload: ByteBuffer(string: "late"))
        }
        defer { publisher.cancel() }

        await inbox.waitForPull(until: ContinuousClock.now.advanced(by: .seconds(3)))
        let messages = inbox.take(upTo: 1, maxBytes: nil)
        let status = inbox.endPull()

        #expect(messages.count == 1, "pull 2 ended early on pull 1's status")
        #expect(status == nil, "a status for another pull was recorded: \(String(describing: status))")
        await inbox.close()
    }

    @Test("A message that arrives after its fetch gave up is kept for the next fetch", .timeLimit(.minutes(1)))
    func lateMessageIsKept() async throws {
        guard let h = try await harness(port: 14264) else { return }
        defer { Task { await h.tearDown() } }

        let stream = try await stream(h.js, "FETCH_LATE")
        let consumer = try await stream.createConsumer(config: ConsumerConfig(
            name: "late", deliverPolicy: .new, ackPolicy: .none
        ))
        let name = await consumer.name
        let inbox = try await PullInbox.open(client: h.client)
        let subject = h.js.consumerNextSubject(stream: "FETCH_LATE", consumer: name)

        // The server holds this pull for 3s; the client gives up after 100ms,
        // which is what happens when a fetch's deadline beats the server's.
        let reply = inbox.beginPull(wanted: 1)
        try await h.client.publish(subject, payload: h.js.encode(NextMessageRequest(batch: 1, expires: 3_000_000_000)), reply: reply)
        await inbox.waitForPull(until: ContinuousClock.now.advanced(by: .milliseconds(100)))
        #expect(inbox.take(upTo: 1, maxBytes: nil).isEmpty)
        _ = inbox.endPull()

        _ = try await h.js.publish("FETCH_LATE.x", payload: ByteBuffer(string: "after the deadline"))

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var kept: [NatsMessage] = []
        while kept.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            kept = inbox.take(upTo: 1, maxBytes: nil)
        }
        #expect(kept.count == 1, "the ack-none delivery that landed after the deadline was dropped")
        await inbox.close()
    }

    @Test("Fetch still ends promptly on an idle consumer and after many empty pulls", .timeLimit(.minutes(1)))
    func emptyFetchesStayBounded() async throws {
        guard let h = try await harness(port: 14265) else { return }
        defer { Task { await h.tearDown() } }

        let stream = try await stream(h.js, "FETCH_IDLE")
        let consumer = try await stream.createConsumer(config: ConsumerConfig(name: "idle", ackPolicy: .explicit))

        let started = ContinuousClock.now
        for _ in 0..<5 {
            let messages = try await consumer.fetch(batch: 10, maxWait: .milliseconds(200))
            #expect(messages.isEmpty)
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(4), "five 200ms fetches took \(elapsed)")

        _ = try await h.js.publish("FETCH_IDLE.x", payload: ByteBuffer(string: "one"))
        let messages = try await consumer.fetch(batch: 10, maxWait: .milliseconds(500))
        #expect(messages.count == 1)
    }

    // MARK: - Fetch: max_bytes and status handling

    @Test("maxBytes bounds a fetch by size", .timeLimit(.minutes(2)))
    func maxBytesBoundsTheBatch() async throws {
        guard let h = try await harness(port: 14266) else { return }
        defer { Task { await h.tearDown() } }

        let stream = try await stream(h.js, "FETCH_BYTES")
        try await publish(h.js, "FETCH_BYTES.x", count: 2000, size: 1024)
        let consumer = try await stream.createConsumer(config: ConsumerConfig(name: "bytes", ackPolicy: .none))

        let messages = try await consumer.fetch(batch: 100_000, maxBytes: 1_048_576, maxWait: .seconds(5))
        #expect((900...1024).contains(messages.count), "expected about a thousand 1 KB messages in 1 MiB, got \(messages.count)")

        // The server ends a byte-bounded pull with the same 409 it uses for a
        // message that does not fit at all. Here it only meant "budget spent",
        // so the next fetch must not inherit it as an error.
        let next = try await consumer.fetch(batch: 100_000, maxBytes: 1_048_576, maxWait: .seconds(5))
        #expect((900...1024).contains(next.count), "second byte-bounded fetch returned \(next.count)")
    }

    @Test("A message larger than maxBytes is reported, not returned as an empty batch", .timeLimit(.minutes(1)))
    func oversizedMessageThrows() async throws {
        guard let h = try await harness(port: 14267) else { return }
        defer { Task { await h.tearDown() } }

        let stream = try await stream(h.js, "FETCH_BIG")
        try await publish(h.js, "FETCH_BIG.x", count: 1, size: 4096)
        let consumer = try await stream.createConsumer(config: ConsumerConfig(name: "big", ackPolicy: .none))

        do {
            let messages = try await consumer.fetch(batch: 10, maxBytes: 512, maxWait: .seconds(2))
            Issue.record("expected messageExceedsMaxBytes, got \(messages.count) messages")
        } catch let error as JetStreamError {
            guard case .messageExceedsMaxBytes(let maxBytes) = error else {
                Issue.record("expected messageExceedsMaxBytes, got \(error)")
                return
            }
            #expect(maxBytes == 512)
        } catch {
            Issue.record("expected messageExceedsMaxBytes, got \(error)")
        }
    }

    @Test("A consumer deleted during a fetch is reported", .timeLimit(.minutes(1)))
    func deletedConsumerThrows() async throws {
        guard let h = try await harness(port: 14268) else { return }
        defer { Task { await h.tearDown() } }

        let stream = try await stream(h.js, "FETCH_GONE")
        let consumer = try await stream.createConsumer(config: ConsumerConfig(name: "gone", ackPolicy: .explicit))

        let deleter = Task {
            try await Task.sleep(for: .milliseconds(300))
            try await h.js.deleteConsumer(stream: "FETCH_GONE", consumer: "gone")
        }
        defer { deleter.cancel() }

        do {
            let messages = try await consumer.fetch(batch: 10, maxWait: .seconds(5))
            Issue.record("expected consumerNotFound, got \(messages.count) messages")
        } catch let error as JetStreamError {
            guard case .consumerNotFound = error else {
                Issue.record("expected consumerNotFound, got \(error)")
                return
            }
        } catch {
            Issue.record("expected consumerNotFound, got \(error)")
        }
    }

    // MARK: - Listings

    private func bucket(_ js: JetStreamContext, _ name: String, keys: Int) async throws -> KeyValueBucket {
        let kv = try await js.createKeyValue(KeyValueConfig(bucket: name))
        let client = await js.natsClient
        for i in 0..<keys {
            try await client.publish("$KV.\(name).k\(i)", payload: ByteBuffer(string: "v"))
        }
        // Core publishes are fire-and-forget; wait until the stream has them all.
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if try await kv.status().values >= keys { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return kv
    }

    @Test("keys() lists every key and keyBatches streams them in bounded batches", .timeLimit(.minutes(2)))
    func listingsAreCompleteAndBounded() async throws {
        guard let h = try await harness(port: 14269) else { return }
        defer { Task { await h.tearDown() } }

        let kv = try await bucket(h.js, "LISTING", keys: 5000)
        try await kv.delete("k0")

        let keys = try await kv.keys()
        #expect(keys.count == 4999)
        #expect(Set(keys).count == 4999)
        #expect(!keys.contains("k0"))

        var total = 0
        var largest = 0
        for try await batch in kv.keyBatches(batch: 500) {
            total += batch.count
            largest = max(largest, batch.count)
        }
        #expect(total == 4999)
        #expect(largest <= 500, "a batch held \(largest) keys against a batch size of 500")
    }

    @Test("A listing cut short by an empty fetch is reported as incomplete", .timeLimit(.minutes(1)))
    func shortListingThrows() async throws {
        guard let h = try await harness(port: 14270) else { return }
        defer { Task { await h.tearDown() } }

        _ = try await bucket(h.js, "SHORT", keys: 50)

        let calls = Counter()
        let scan = KeyValueScan(
            context: h.js, bucket: "SHORT", filterSubject: "$KV.SHORT.>",
            deliverPolicy: .lastPerSubject, headersOnly: true, batch: 10,
            fetch: { consumer, batch in
                // Two real batches, then every pull comes back empty.
                calls.increment() <= 2 ? try await consumer.fetch(batch: batch, maxWait: .seconds(5)) : []
            }
        )

        var received = 0
        do {
            while let messages = try await scan.next() {
                received += messages.count
            }
            Issue.record("expected incompleteListing after \(received) entries")
        } catch let error as JetStreamError {
            guard case .incompleteListing(_, let listed, let pending) = error else {
                Issue.record("expected incompleteListing, got \(error)")
                return
            }
            #expect(listed == 20)
            #expect(pending == 30)
        } catch {
            Issue.record("expected incompleteListing, got \(error)")
        }
    }

    @Test("A single empty fetch mid-listing is retried, not reported", .timeLimit(.minutes(1)))
    func transientEmptyFetchRecovers() async throws {
        guard let h = try await harness(port: 14271) else { return }
        defer { Task { await h.tearDown() } }

        _ = try await bucket(h.js, "RETRY", keys: 50)

        let calls = Counter()
        let scan = KeyValueScan(
            context: h.js, bucket: "RETRY", filterSubject: "$KV.RETRY.>",
            deliverPolicy: .lastPerSubject, headersOnly: true, batch: 10,
            fetch: { consumer, batch in
                calls.increment() == 3 ? [] : try await consumer.fetch(batch: batch, maxWait: .seconds(5))
            }
        )

        var received = 0
        while let messages = try await scan.next() {
            received += messages.count
        }
        #expect(received == 50)
    }

    // MARK: - Tombstone purges

    @Test("Purging a known marker does not remove a value written after it", .timeLimit(.minutes(1)))
    func markerPurgeIsRevisionBounded() async throws {
        guard let h = try await harness(port: 14272) else { return }
        defer { Task { await h.tearDown() } }

        let kv = try await h.js.createKeyValue(KeyValueConfig(bucket: "TOMBSTONES", history: 5))

        // "gone": deleted and stays deleted.
        try await kv.put("gone", value: "v1")
        try await kv.delete("gone")
        // "back": deleted, then written again before the purge runs.
        try await kv.put("back", value: "v1")
        try await kv.delete("back")

        var markers: [KeyValueEntry] = []
        for key in ["gone", "back"] {
            let history = try await kv.history(key)
            if let marker = history.last, marker.operation == .delete {
                markers.append(marker)
            }
        }
        #expect(markers.count == 2)

        try await kv.put("back", value: "v2")

        let acted = try await kv.purgeDeletes(markers)
        #expect(acted == 2)

        #expect(try await kv.history("gone").isEmpty, "the deleted key's marker and history should be gone")
        let back = try await kv.get("back")
        #expect(back?.stringValue == "v2", "the value written after the marker was purged")
    }

    @Test("purgeDeletes(olderThan:) keeps recent markers and removes the history before them", .timeLimit(.minutes(1)))
    func recentMarkersAreKept() async throws {
        guard let h = try await harness(port: 14273) else { return }
        defer { Task { await h.tearDown() } }

        let kv = try await h.js.createKeyValue(KeyValueConfig(bucket: "RECENT", history: 5))
        try await kv.put("k", value: "v1")
        try await kv.put("k", value: "v2")
        try await kv.delete("k")

        try await kv.purgeDeletes(olderThan: .seconds(3600))

        let history = try await kv.history("k")
        #expect(history.count == 1, "expected only the marker, got \(history.map(\.operation))")
        #expect(history.first?.operation == .delete)
    }

    // MARK: - Watch resume

    @Test("A watcher resumed from a revision receives exactly what came after it", .timeLimit(.minutes(1)))
    func watchResumesFromRevision() async throws {
        guard let h = try await harness(port: 14274) else { return }
        defer { Task { await h.tearDown() } }

        let kv = try await h.js.createKeyValue(KeyValueConfig(bucket: "RESUME"))
        for i in 0..<5 {
            try await kv.put("k\(i)", value: "v")
        }

        var lastRevision: UInt64 = 0
        let first = try await kv.watchAll()
        for try await entry in first {
            guard let entry else { break }
            lastRevision = max(lastRevision, entry.revision)
        }
        try await first.stop()
        #expect(lastRevision == 5)

        for i in 5..<8 {
            try await kv.put("k\(i)", value: "v")
        }

        let status = try await kv.status()
        #expect(status.firstRevision <= lastRevision + 1, "resume point was purged")

        var resumed: [String] = []
        let second = try await kv.watchAll(options: KeyValueWatchOptions(resumeFromRevision: lastRevision + 1))
        for try await entry in second {
            guard let entry else { break }
            resumed.append(entry.key)
        }
        try await second.stop()

        #expect(resumed == ["k5", "k6", "k7"])
    }

    @Test("A watcher's replay does not wait out the pull expiry on its last batch", .timeLimit(.minutes(1)))
    func watchReplayDoesNotStall() async throws {
        guard let h = try await harness(port: 14280) else { return }
        defer { Task { await h.tearDown() } }

        // Not a multiple of the watcher's batch, so the last pull is partial.
        let kv = try await bucket(h.js, "REPLAY", keys: 300)

        let started = ContinuousClock.now
        var received = 0
        let watcher = try await kv.watchAll()
        for try await entry in watcher {
            guard entry != nil else { break }
            received += 1
        }
        let elapsed = ContinuousClock.now - started
        try await watcher.stop()

        #expect(received == 300)
        #expect(elapsed < .seconds(2), "replay of 300 keys took \(elapsed); the last partial pull waited for its expiry")
    }

    @Test("A caught-up watcher delivers an update as it happens", .timeLimit(.minutes(1)))
    func caughtUpWatcherIsPrompt() async throws {
        guard let h = try await harness(port: 14281) else { return }
        defer { Task { await h.tearDown() } }

        let kv = try await h.js.createKeyValue(KeyValueConfig(bucket: "PROMPT"))
        try await kv.put("seed", value: "v")

        let watcher = try await kv.watchAll()
        let caughtUp = ResultBox<Bool>()
        let updateArrived = ResultBox<ContinuousClock.Instant>()
        let reader = Task {
            for try await entry in watcher {
                guard let entry else {
                    caughtUp.set(true)
                    continue
                }
                if entry.key == "update" {
                    updateArrived.set(ContinuousClock.now)
                    return
                }
            }
        }
        defer { reader.cancel() }

        let ready = await boundedly(.seconds(10)) { () -> Bool in
            while caughtUp.value == nil { try? await Task.sleep(for: .milliseconds(10)) }
            return true
        }
        #expect(ready == true, "the watcher never delivered its initial values")

        let putAt = ContinuousClock.now
        try await kv.put("update", value: "v")
        let update = await boundedly(.seconds(10)) { () -> Duration in
            while updateArrived.value == nil { try? await Task.sleep(for: .milliseconds(5)) }
            return updateArrived.value! - putAt
        }
        try await watcher.stop()

        let latency = try #require(update, "the update never arrived")
        #expect(latency < .seconds(1), "update took \(latency) to reach a caught-up watcher")
    }

    // MARK: - Connection paths

    @Test("Concurrent first requests share one inbox subscription", .timeLimit(.minutes(1)))
    func concurrentRequestsShareTheInbox() async throws {
        guard let h = try await harness(port: 14275) else { return }
        defer { Task { await h.tearDown() } }

        let responder = NatsClient(options: NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:14275")!]))
        try await responder.connect()
        let service = try await responder.subscribe("svc.echo")
        let replies = Task {
            for await request in service {
                guard let reply = request.replyTo else { continue }
                try? await responder.publish(reply, payload: request.buffer)
            }
        }
        defer {
            replies.cancel()
            Task { await responder.close() }
        }
        try await Task.sleep(for: .milliseconds(200))

        let fresh = NatsClient(options: NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:14275")!]))
        try await fresh.connect()
        defer { Task { await fresh.close() } }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<256 {
                group.addTask {
                    let reply = try await fresh.request("svc.echo", payload: ByteBuffer(string: "\(i)"), timeout: .seconds(10))
                    #expect(reply.buffer.getString(at: reply.buffer.readerIndex, length: reply.buffer.readableBytes) == "\(i)")
                }
            }
            try await group.waitForAll()
        }

        let subscriptions = await fresh.subscriptionCountForTesting
        #expect(subscriptions == 1, "concurrent first requests created \(subscriptions) inbox subscriptions")
    }

    @Test("Messages reach a subscriber in publish order", .timeLimit(.minutes(1)))
    func deliveryPreservesOrder() async throws {
        guard let h = try await harness(port: 14276) else { return }
        defer { Task { await h.tearDown() } }

        let subscriber = NatsClient(options: NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:14276")!]))
        try await subscriber.connect()
        defer { Task { await subscriber.close() } }
        let subscription = try await subscriber.subscribe("order.test")
        try await Task.sleep(for: .milliseconds(200))

        let count = 20_000
        for i in 0..<count {
            try await h.client.publish("order.test", payload: ByteBuffer(string: String(i)))
        }

        let outOfOrder = await boundedly(.seconds(30)) { () -> Int in
            var expected = 0
            var misses = 0
            for await message in subscription {
                let value = Int(message.buffer.getString(at: message.buffer.readerIndex, length: message.buffer.readableBytes) ?? "") ?? -1
                if value != expected { misses += 1 }
                expected = value + 1
                if value == count - 1 { break }
            }
            return misses
        }
        #expect(outOfOrder == 0, "messages were reordered or lost: \(String(describing: outOfOrder))")
    }

    @Test("Messages published just before close are delivered", .timeLimit(.minutes(1)))
    func publishThenCloseDelivers() async throws {
        guard let h = try await harness(port: 14278) else { return }
        defer { Task { await h.tearDown() } }

        let subscription = try await h.client.subscribe("close.flush")
        try await Task.sleep(for: .milliseconds(200))

        let publisher = NatsClient(options: NatsClientOptions(servers: [URL(string: "nats://127.0.0.1:14278")!]))
        try await publisher.connect()
        // Publishes return once queued, so close() has to flush what is still
        // queued. Against a local server the kernel usually absorbs the frames
        // anyway, so this guards the path rather than proving the flush; the
        // bound on that flush is covered by the stalled-peer write tests, which
        // close inline.
        let count = 100
        var payload = ByteBuffer()
        payload.writeRepeatingByte(0x62, count: 256 * 1024)
        for _ in 0..<count {
            try await publisher.publish("close.flush", payload: payload)
        }
        await publisher.close()

        let received = await boundedly(.seconds(10)) { () -> Int in
            var received = 0
            for await _ in subscription {
                received += 1
                if received == count { break }
            }
            return received
        }
        #expect(received == count, "publishes queued at close were dropped: \(String(describing: received)) of \(count)")
    }

    @Test("A cancelled request unwinds promptly", .timeLimit(.minutes(1)))
    func cancelledRequestUnwinds() async throws {
        guard let h = try await harness(port: 14277) else { return }
        defer { Task { await h.tearDown() } }

        // Subscribed but never answers, so only cancellation can end the request.
        let silent = try await h.client.subscribe("svc.silent")
        _ = silent

        let outcome = ResultBox<OperationOutcome>()
        let requester = Task {
            outcome.set(await OperationOutcome {
                _ = try await h.client.request("svc.silent", timeout: .seconds(60))
            })
        }
        try await Task.sleep(for: .milliseconds(200))
        requester.cancel()

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while outcome.value == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(outcome.value?.isFailure == true, "request ignored cancellation: \(String(describing: outcome.value))")
    }
}

/// Thread-safe call counter for fetch overrides.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Increments and returns the new count.
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}
