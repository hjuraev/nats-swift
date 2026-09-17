// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// One pass over a bucket's entries through a throwaway pull consumer, a batch
/// at a time as the caller asks for it.
///
/// Shared by `keys`, `keyBatches`, `history` and `purgeDeletes`. Two things the
/// loops it replaces got wrong:
///
/// - **Knowing when it is done.** Each delivery carries the consumer's pending
///   count, so the pass ends when a message reports nothing pending, or when as
///   many entries as were pending at the start have arrived — the same rule the
///   Go client uses. An empty fetch is not treated as the end: the consumer is
///   asked, and a listing that stops with entries still pending throws
///   `incompleteListing` instead of returning a partial result as success.
/// - **Holding the bucket in memory.** Batches are fetched on demand, so a
///   caller streaming keys holds one batch at a time.
actor KeyValueScan {
    private let context: JetStreamContext
    private let bucket: String
    private let streamName: String
    private let config: ConsumerConfig
    private let batchSize: Int

    /// How a batch is pulled. Tests replace it to stage a pull that comes back
    /// empty with entries still pending.
    typealias Fetch = @Sendable (Consumer, Int) async throws -> [JetStreamMessage]
    private let fetch: Fetch

    private var consumer: Consumer?
    private var initialPending: UInt64 = 0
    private var pending: UInt64 = 0
    private var received = 0
    private var finished = false

    /// Empty fetches tolerated while the consumer still reports entries
    /// pending, before the listing is declared incomplete. One covers a pull
    /// lost across a reconnect; more would only delay the report.
    private static let emptyFetchRetries = 2

    init(
        context: JetStreamContext,
        bucket: String,
        filterSubject: String,
        deliverPolicy: DeliverPolicy,
        headersOnly: Bool,
        batch: Int,
        fetch: Fetch? = nil
    ) {
        self.fetch = fetch ?? { consumer, batch in
            try await consumer.fetch(batch: batch, maxWait: .seconds(5))
        }
        self.context = context
        self.bucket = bucket
        self.streamName = "KV_\(bucket)"
        self.batchSize = max(1, batch)
        self.config = ConsumerConfig(
            deliverPolicy: deliverPolicy,
            ackPolicy: .none,
            filterSubject: filterSubject,
            inactiveThreshold: .seconds(300),
            memStorage: true,
            headersOnly: headersOnly ? true : nil
        )
    }

    deinit {
        // Abandoned mid-pass: remove the consumer now rather than leaving it to
        // the inactivity threshold.
        if let consumer, !finished {
            let context = self.context
            let streamName = self.streamName
            Task {
                let name = await consumer.name
                try? await context.deleteConsumer(stream: streamName, consumer: name)
            }
        }
    }

    /// The next batch of entries, or nil once every pending entry has arrived.
    func next() async throws(JetStreamError) -> [JetStreamMessage]? {
        guard !finished else { return nil }

        let consumer = try await start()
        guard let consumer else { return nil }

        var emptyFetches = 0
        while true {
            // Never ask for more than is pending: a pull for a batch the stream
            // cannot fill waits out its whole expiry before returning.
            let want = Int(min(UInt64(batchSize), max(pending, 1)))
            let messages: [JetStreamMessage]
            do {
                messages = try await fetch(consumer, want)
            } catch {
                await finish()
                throw JetStreamError.mapping(error, operation: "fetch", timeout: .seconds(5))
            }

            guard let last = messages.last else {
                do {
                    try await consumer.refresh()
                } catch {
                    await finish()
                    throw error
                }
                let info = await consumer.info
                pending = info.numPending
                // Nothing pending means everything was *delivered*, not that it
                // was received: a delivery that landed after the fetch gave up
                // waits in the consumer's inbox for the next fetch.
                let unread = info.delivered.consumerSeq > UInt64(received)
                    ? info.delivered.consumerSeq - UInt64(received)
                    : 0
                if pending == 0 && unread == 0 {
                    await finish()
                    return nil
                }
                emptyFetches += 1
                if emptyFetches > Self.emptyFetchRetries {
                    await finish()
                    throw JetStreamError.incompleteListing(bucket: bucket, received: received, pending: pending + unread)
                }
                continue
            }

            received += messages.count
            pending = last.metadata.numPending
            if pending == 0 || received >= initialPending {
                await finish()
            }
            return messages
        }
    }

    /// Create the consumer on first use. Returns nil when nothing is pending.
    private func start() async throws(JetStreamError) -> Consumer? {
        if let consumer {
            return consumer
        }
        let created = try await context.createConsumer(stream: streamName, config: config)
        consumer = created
        initialPending = await created.info.numPending
        pending = initialPending
        if initialPending == 0 {
            await finish()
            return nil
        }
        return created
    }

    private func finish() async {
        guard !finished else { return }
        finished = true
        if let consumer {
            // Not awaited: the caller has its entries, and a slow delete must
            // not hold them back. The inactivity threshold covers a lost one.
            Task { try? await consumer.delete() }
        }
    }
}

/// A bucket's keys, delivered a batch at a time as the caller iterates.
///
/// Holds one batch of keys at a time, however large the bucket. Throws
/// `incompleteListing` if the listing ends with keys still pending.
public struct KeyValueKeyBatches: AsyncSequence, Sendable {
    public typealias Element = [String]

    private let makeScan: @Sendable () -> KeyValueScan
    private let keyPrefix: String

    init(keyPrefix: String, makeScan: @escaping @Sendable () -> KeyValueScan) {
        self.keyPrefix = keyPrefix
        self.makeScan = makeScan
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let scan: KeyValueScan
        private let keyPrefix: String

        init(scan: KeyValueScan, keyPrefix: String) {
            self.scan = scan
            self.keyPrefix = keyPrefix
        }

        public mutating func next() async throws -> [String]? {
            // A batch of nothing but delete markers yields no keys; keep going
            // rather than hand the caller an empty batch.
            while let messages = try await scan.next() {
                let keys = KeyValueKeyBatches.activeKeys(in: messages, keyPrefix: keyPrefix)
                if !keys.isEmpty {
                    return keys
                }
            }
            return nil
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(scan: makeScan(), keyPrefix: keyPrefix)
    }

    /// Keys of the entries in `messages` that are not delete or purge markers.
    static func activeKeys(in messages: [JetStreamMessage], keyPrefix: String) -> [String] {
        messages.compactMap { message in
            let subject = message.subject
            guard subject.hasPrefix(keyPrefix) else { return nil }
            if let operation = message.headers?[NatsHeaders.Keys.kvOperation],
               operation == "DEL" || operation == "PURGE" {
                return nil
            }
            return String(subject.dropFirst(keyPrefix.count))
        }
    }
}
