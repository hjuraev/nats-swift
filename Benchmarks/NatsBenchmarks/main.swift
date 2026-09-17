// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

// Throughput benchmarks for the client's hot paths (nats#2).
//
//     swift run -c release NatsBenchmarks [publish|subscribe|put|get|fetch|keys|watch|all]
//
// Needs a JetStream-enabled server at NATS_URL (default nats://127.0.0.1:4222).
// Creates and deletes its own streams and buckets (prefix BENCH_).
//
// Measure on Linux, in release. On macOS the Swift runtime can record a
// signpost with a backtrace on every actor enqueue, which inflates per-hop
// costs several-fold and flattens every concurrency curve.

import Foundation
import Nats
import NIOCore
import Logging

let url = URL(string: ProcessInfo.processInfo.environment["NATS_URL"] ?? "nats://127.0.0.1:4222")!
let mode = CommandLine.arguments.dropFirst().first ?? "all"

func connect() async throws -> NatsClient {
    var options = NatsClientOptions(servers: [url])
    options.logger.logLevel = ProcessInfo.processInfo.environment["NATS_BENCH_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    let client = NatsClient(options: options)
    try await client.connect()
    return client
}

func seconds(since start: ContinuousClock.Instant) -> Double {
    (ContinuousClock.now - start) / .seconds(1)
}

func report(_ name: String, _ count: Int, _ start: ContinuousClock.Instant, unit: String = "msgs") {
    let elapsed = seconds(since: start)
    let label = name.padding(toLength: 32, withPad: " ", startingAt: 0)
    print(label + String(format: "%9d %@ in %6.2fs  %10.0f/s", count, unit, elapsed, Double(count) / elapsed))
}

/// Fire-and-forget publishes from one sequential loop.
func benchPublish() async throws {
    let client = try await connect()
    let count = 100_000
    let payload = ByteBuffer(string: String(repeating: "x", count: 64))
    let start = ContinuousClock.now
    for _ in 0..<count {
        try await client.publish("BENCH.publish", payload: payload)
    }
    report("publish, sequential, 64 B", count, start)
    await client.close()
}

/// Acked KV puts at increasing concurrency.
func benchPut() async throws {
    let client = try await connect()
    let js = try await client.jetStream()
    try? await js.deleteKeyValue("BENCH_PUT")
    let kv = try await js.createKeyValue(KeyValueConfig(bucket: "BENCH_PUT"))

    for concurrency in [1, 16, 256] {
        let count = concurrency == 1 ? 5_000 : 50_000
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            for _ in 0..<concurrency {
                let i = next; next += 1
                group.addTask { try await kv.put("k\(i % 1024)", value: "v") }
            }
            while try await group.next() != nil, next < count {
                let i = next; next += 1
                group.addTask { try await kv.put("k\(i % 1024)", value: "v") }
            }
            try await group.waitForAll()
        }
        report("kv.put, \(concurrency) in flight", count, start)
    }

    try? await js.deleteKeyValue("BENCH_PUT")
    await client.close()
}

/// Fill a bucket of `keys` keys with core publishes, waiting until stored.
func fillBucket(_ js: JetStreamContext, _ client: NatsClient, name: String, keys: Int) async throws -> KeyValueBucket {
    try? await js.deleteKeyValue(name)
    let kv = try await js.createKeyValue(KeyValueConfig(bucket: name))
    let payload = ByteBuffer(string: "v")
    for i in 0..<keys {
        try await client.publish("$KV.\(name).k\(i)", payload: payload)
    }
    while try await kv.status().values < keys {
        try await Task.sleep(for: .milliseconds(100))
    }
    return kv
}

/// Pull fetches over a large last-per-subject replay, at two batch sizes, to
/// separate the per-fetch cost from the per-message cost.
func benchFetch() async throws {
    let client = try await connect()
    let js = try await client.jetStream()
    let keys = 200_000
    _ = try await fillBucket(js, client, name: "BENCH_FETCH", keys: keys)

    var perFetch: [(batch: Int, msPerFetch: Double)] = []
    for batch in [64, 1024] {
        let consumer = try await js.createConsumer(stream: "KV_BENCH_FETCH", config: ConsumerConfig(
            deliverPolicy: .lastPerSubject, ackPolicy: .none, filterSubject: "$KV.BENCH_FETCH.>",
            inactiveThreshold: .seconds(60), memStorage: true, headersOnly: true
        ))
        let limit = 64_000
        var received = 0
        var fetches = 0
        let start = ContinuousClock.now
        while received < limit {
            let messages = try await consumer.fetch(batch: batch, maxWait: .seconds(5))
            if messages.isEmpty { break }
            received += messages.count
            fetches += 1
        }
        report("fetch, batch \(batch)", received, start)
        perFetch.append((batch, seconds(since: start) * 1000 / Double(fetches)))
        try? await consumer.delete()
    }
    let (small, large) = (perFetch[0], perFetch[1])
    let perMessage = (large.msPerFetch - small.msPerFetch) / Double(large.batch - small.batch)
    let fixed = small.msPerFetch - Double(small.batch) * perMessage
    print(String(format: "  fit: %.3f ms per fetch + %.1f µs per message", fixed, perMessage * 1000))

    try? await js.deleteKeyValue("BENCH_FETCH")
    await client.close()
}

/// Whole-bucket key listing.
func benchKeys() async throws {
    let client = try await connect()
    let js = try await client.jetStream()
    let kv = try await fillBucket(js, client, name: "BENCH_KEYS", keys: 200_000)

    let start = ContinuousClock.now
    let keys = try await kv.keys()
    report("kv.keys(), 200k keys", keys.count, start, unit: "keys")

    try? await js.deleteKeyValue("BENCH_KEYS")
    await client.close()
}

/// Concurrent KV gets of existing keys.
func benchGet() async throws {
    let client = try await connect()
    let js = try await client.jetStream()
    try? await js.deleteKeyValue("BENCH_GET")
    let kv = try await js.createKeyValue(KeyValueConfig(bucket: "BENCH_GET"))
    for i in 0..<1024 {
        try await kv.put("k\(i)", value: "value-\(i)")
    }

    let count = 50_000
    let start = ContinuousClock.now
    try await withThrowingTaskGroup(of: Void.self) { group in
        var next = 0
        for _ in 0..<64 {
            let i = next; next += 1
            group.addTask { _ = try await kv.get("k\(i % 1024)") }
        }
        while try await group.next() != nil, next < count {
            let i = next; next += 1
            group.addTask { _ = try await kv.get("k\(i % 1024)") }
        }
        try await group.waitForAll()
    }
    report("kv.get, 64 in flight", count, start)

    try? await js.deleteKeyValue("BENCH_GET")
    await client.close()
}

/// A watcher's initial replay of a large bucket.
func benchWatch() async throws {
    let client = try await connect()
    let js = try await client.jetStream()
    let kv = try await fillBucket(js, client, name: "BENCH_WATCH", keys: 200_000)

    let start = ContinuousClock.now
    var received = 0
    let watcher = try await kv.watchAll()
    for try await entry in watcher {
        guard entry != nil else { break }
        received += 1
    }
    try await watcher.stop()
    report("kv.watchAll() replay, 200k keys", received, start, unit: "keys")

    try? await js.deleteKeyValue("BENCH_WATCH")
    await client.close()
}

/// Core subscription throughput, publisher and subscriber on separate connections.
func benchSubscribe() async throws {
    let subscriber = try await connect()
    let publisher = try await connect()
    let subscription = try await subscriber.subscribe("BENCH.sub")
    try await Task.sleep(for: .milliseconds(200))

    let count = 200_000
    let payload = ByteBuffer(string: String(repeating: "x", count: 64))
    let start = ContinuousClock.now
    let pump = Task {
        for _ in 0..<count {
            try await publisher.publish("BENCH.sub", payload: payload)
        }
    }
    var received = 0
    for await _ in subscription {
        received += 1
        if received == count { break }
    }
    report("subscribe, receive 64 B", received, start)
    _ = try? await pump.value

    await publisher.close()
    await subscriber.close()
}

switch mode {
case "publish": try await benchPublish()
case "put": try await benchPut()
case "fetch": try await benchFetch()
case "keys": try await benchKeys()
case "get": try await benchGet()
case "watch": try await benchWatch()
case "subscribe": try await benchSubscribe()
default:
    try await benchPublish()
    try await benchSubscribe()
    try await benchPut()
    try await benchGet()
    try await benchFetch()
    try await benchKeys()
    try await benchWatch()
}
