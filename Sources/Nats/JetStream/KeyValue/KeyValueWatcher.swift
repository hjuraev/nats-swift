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

    /// Resume watching from a specific revision (deliverPolicy: .byStartSequence)
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

                while !Task.isCancelled {
                    do {
                        let messages = try await consumer.fetch(batch: 256, maxWait: .seconds(5))

                        for msg in messages {
                            let entry = KeyValueEntry.fromConsumerMessage(msg, bucket: bucket)
                            continuation.yield(entry)
                            received += 1
                        }

                        // After receiving all initial pending messages, send nil sentinel
                        if !sentInitialDone && received >= initialPending {
                            continuation.yield(nil)
                            sentInitialDone = true
                        }

                        if messages.isEmpty && !sentInitialDone {
                            // No messages and no initial pending — send sentinel
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
