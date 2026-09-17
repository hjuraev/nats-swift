// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import NIOCore

/// Options for watching key changes
public struct KeyValueWatchOptions: Sendable {
    /// Include all historical values (deliverPolicy: .all)
    public var includeHistory: Bool

    /// Only receive updates after the watcher is created (deliverPolicy: .new)
    public var updatesOnly: Bool

    /// Only receive headers (no values) — useful for key enumeration
    public var metaOnly: Bool

    /// Resume watching from a specific revision, inclusive
    /// (deliverPolicy: .byStartSequence).
    ///
    /// A watcher that lost its consumer — a broker restart, the inactivity
    /// threshold — and still holds a valid image can pass its last revision
    /// + 1 here and receive only what changed since, instead of replaying the
    /// whole bucket.
    ///
    /// Two ways the resume can miss changes, which the caller must rule out
    /// before trusting it:
    ///
    /// - **The revision was purged from the head of the stream.** If
    ///   `KeyValueBucketStatus.firstRevision` is above the resume revision,
    ///   entries in between are gone; replay the bucket instead.
    /// - **A delete marker after it was removed.** `purgeDeletes` removes old
    ///   markers outright, from anywhere in the stream. A key deleted while the
    ///   watcher was away, whose marker was then purged, never appears in the
    ///   resumed stream, and the image keeps a key that no longer exists. Resume
    ///   only if the watcher was away for less than the `olderThan` the bucket's
    ///   `purgeDeletes` runs with.
    public var resumeFromRevision: UInt64?

    public init(
        includeHistory: Bool = false,
        updatesOnly: Bool = false,
        metaOnly: Bool = false,
        resumeFromRevision: UInt64? = nil
    ) {
        self.includeHistory = includeHistory
        self.updatesOnly = updatesOnly
        self.metaOnly = metaOnly
        self.resumeFromRevision = resumeFromRevision
    }
}

/// Owns the pump task and continuation behind a watcher, so the watcher can
/// actually be stopped.
///
/// `stop()` used to delete the consumer and nothing else: the pump kept looping
/// and the stream was never finished, so anyone iterating the watcher stayed
/// suspended indefinitely on a watcher they had explicitly stopped.
final class KeyValueWatcherHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var pump: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<KeyValueEntry?, Error>.Continuation?
    private var stopped = false

    func arm(continuation: AsyncThrowingStream<KeyValueEntry?, Error>.Continuation) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func arm(pump: Task<Void, Never>) {
        lock.lock()
        let alreadyStopped = stopped
        if !alreadyStopped { self.pump = pump }
        lock.unlock()
        // Stopped before the pump was even attached — do not leave it running.
        if alreadyStopped { pump.cancel() }
    }

    /// Cancel the pump and end the stream. Idempotent.
    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let pump = self.pump
        let continuation = self.continuation
        self.pump = nil
        self.continuation = nil
        lock.unlock()

        pump?.cancel()
        // Finish directly rather than waiting for the pump to notice: it may be
        // parked in a multi-second fetch, and a stopped watcher should not make
        // its consumer wait that out.
        continuation?.finish()
    }
}

/// An async sequence that yields KV entry updates.
/// A nil element signals that all initial values have been delivered.
public struct KeyValueWatcher: AsyncSequence, Sendable {
    public typealias Element = KeyValueEntry?

    private let stream: AsyncThrowingStream<KeyValueEntry?, Error>
    private let consumerName: String
    private let streamName: String
    private let context: JetStreamContext
    private let handle: KeyValueWatcherHandle

    init(
        stream: AsyncThrowingStream<KeyValueEntry?, Error>,
        consumerName: String,
        streamName: String,
        context: JetStreamContext,
        handle: KeyValueWatcherHandle
    ) {
        self.stream = stream
        self.consumerName = consumerName
        self.streamName = streamName
        self.context = context
        self.handle = handle
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<KeyValueEntry?, Error>.AsyncIterator

        public mutating func next() async throws -> KeyValueEntry?? {
            try await base.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: stream.makeAsyncIterator())
    }

    /// Stop the watcher, end its stream, and clean up the consumer.
    ///
    /// Ending the stream is the part that used to be missing: deleting the
    /// consumer stops new data arriving but says nothing to anyone already
    /// iterating, who would wait for a message that could never come.
    public func stop() async throws(JetStreamError) {
        handle.stop()
        do {
            try await context.deleteConsumer(stream: streamName, consumer: consumerName)
        } catch {
            // Consumer may already be deleted (ephemeral timeout)
        }
    }

    /// Largest pull a watcher makes.
    static let maxBatch = 256

    /// Create a new watcher
    static func create(
        context: JetStreamContext,
        bucket: String,
        keyPattern: String,
        options: KeyValueWatchOptions
    ) async throws(JetStreamError) -> KeyValueWatcher {
        let streamName = "KV_\(bucket)"
        let filterSubject = "$KV.\(bucket).\(keyPattern)"

        // Determine deliver policy
        let deliverPolicy: DeliverPolicy
        var optStartSeq: UInt64? = nil

        if options.updatesOnly {
            deliverPolicy = .new
        } else if let rev = options.resumeFromRevision {
            deliverPolicy = .byStartSequence
            optStartSeq = rev
        } else if options.includeHistory {
            deliverPolicy = .all
        } else {
            deliverPolicy = .lastPerSubject
        }

        let consumer = try await context.createConsumer(
            stream: streamName,
            config: ConsumerConfig(
                deliverPolicy: deliverPolicy,
                optStartSeq: optStartSeq,
                ackPolicy: .none,
                filterSubject: filterSubject,
                inactiveThreshold: .seconds(300),
                memStorage: true,
                headersOnly: options.metaOnly ? true : nil
            )
        )

        let consumerName = await consumer.name
        let initialPending = await consumer.info.numPending

        let handle = KeyValueWatcherHandle()
        let asyncStream = AsyncThrowingStream<KeyValueEntry?, Error> { continuation in
            handle.arm(continuation: continuation)

            // A consumer that simply stops iterating must not leave the pump
            // fetching forever behind it.
            continuation.onTermination = { _ in handle.stop() }

            let pump = Task {
                var received: UInt64 = 0
                var sentInitialDone = options.updatesOnly  // If updatesOnly, skip initial done sentinel
                // What the consumer reported still to deliver, as of the last delivery.
                var pending = initialPending
                let keyPrefix = "$KV.\(bucket)."

                while !Task.isCancelled {
                    do {
                        // Never ask for more than is pending. A pull the stream
                        // cannot fill is held by the server until it expires:
                        // every replay ended with a 5 s stall on its last
                        // partial batch, and a watcher that had caught up
                        // delivered each update up to 5 s late. Caught up, it
                        // pulls one at a time and an update arrives as it
                        // happens; a burst raises `pending` and the batch size.
                        let batch = Int(Swift.min(UInt64(Self.maxBatch), Swift.max(pending, 1)))
                        let messages = try await consumer.fetch(batch: batch, maxWait: .seconds(5))

                        for msg in messages {
                            let entry = KeyValueEntry.fromConsumerMessage(msg, bucket: bucket, keyPrefix: keyPrefix)
                            continuation.yield(entry)
                            received += 1
                        }
                        if let last = messages.last {
                            pending = last.metadata.numPending
                        }

                        guard !sentInitialDone else { continue }

                        // The initial values are done when a delivery reports
                        // nothing pending, or when as many have arrived as were
                        // pending at the start (the Go client's rule).
                        if let last = messages.last {
                            if last.metadata.numPending == 0 || received >= initialPending {
                                continuation.yield(nil)
                                sentInitialDone = true
                            }
                            continue
                        }

                        // An empty fetch is not the end of the initial values
                        // by itself — a pull can come back empty with entries
                        // still pending — so it used to signal "done" on a
                        // partial image. Ask the consumer.
                        var settled = initialPending == 0
                        if !settled {
                            // A failed refresh leaves the question open for the
                            // next empty fetch; it does not end the watch.
                            if (try? await consumer.refresh()) != nil {
                                let info = await consumer.info
                                // Delivered but not yet received entries are
                                // still on their way through the inbox.
                                settled = info.numPending == 0 && info.delivered.consumerSeq <= received
                            }
                        }
                        if settled {
                            continuation.yield(nil)
                            sentInitialDone = true
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }

                continuation.finish()
            }
            handle.arm(pump: pump)
        }

        return KeyValueWatcher(
            stream: asyncStream,
            consumerName: consumerName,
            streamName: streamName,
            context: context,
            handle: handle
        )
    }
}
