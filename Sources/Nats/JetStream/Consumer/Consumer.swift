// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// A JetStream consumer handle
public actor Consumer {
    private let context: JetStreamContext
    private var _info: ConsumerInfo
    private let streamName: String

    /// The inbox fetches pull into; opened by the first fetch, reopened after
    /// the connection it lived on is closed.
    private var inbox: PullInbox?

    /// Fetches run one at a time per handle: the inbox tracks one current pull.
    private var fetching = false
    private var fetchWaiters: [CheckedContinuation<Void, Never>] = []

    /// A pull error seen while the same fetch also returned messages. Returning
    /// the messages comes first — on an `ackPolicy: .none` consumer they cannot
    /// be delivered again — and the error is thrown by the next fetch.
    private var deferredError: JetStreamError?

    /// Current consumer information
    public var info: ConsumerInfo { _info }

    /// Consumer name
    public var name: String { _info.name }

    init(context: JetStreamContext, info: ConsumerInfo, streamName: String) {
        self.context = context
        self._info = info
        self.streamName = streamName
    }

    // MARK: - Operations

    /// Refresh consumer information from server
    public func refresh() async throws(JetStreamError) {
        let consumer = try await context.consumer(stream: streamName, name: name)
        self._info = await consumer.info
    }

    /// Delete this consumer
    public func delete() async throws(JetStreamError) {
        try await context.deleteConsumer(stream: streamName, consumer: name)
        if let inbox {
            self.inbox = nil
            await inbox.close()
        }
    }

    // MARK: - Pull Consumption

    /// Fetch a batch of messages.
    ///
    /// Returns when `batch` messages have arrived, `maxBytes` of messages have
    /// arrived, the server reports there is nothing (more) to deliver, or
    /// `maxWait` elapses — possibly with an empty array. `maxWait` defaults to
    /// the JetStream context's request timeout.
    ///
    /// One inbox subscription serves every fetch on this handle, and messages
    /// that arrive after a fetch has returned are kept for the next one rather
    /// than dropped. Concurrent calls on the same handle run one after another.
    ///
    /// - Throws: `messageExceedsMaxBytes` when the next message is larger than
    ///   `maxBytes`; `consumerNotFound` when the server reports the consumer
    ///   deleted; `pullFailed` when the server rejects the request (for example
    ///   a batch above the consumer's `maxBatch`); `notConnected` when the
    ///   connection closed with nothing delivered. A cancelled fetch returns
    ///   what it has collected.
    public func fetch(
        batch: Int = 1,
        maxBytes: Int? = nil,
        maxWait: Duration? = nil
    ) async throws(JetStreamError) -> [JetStreamMessage] {
        await acquireFetch()
        defer { releaseFetch() }

        if let error = deferredError {
            deferredError = nil
            throw error
        }

        let batch = max(1, batch)
        let expires = maxWait ?? context.requestTimeout
        let inbox = try await openInbox()

        // Messages left over from an earlier pull are this fetch's first.
        var collected = inbox.take(upTo: batch, maxBytes: maxBytes)
        var collectedBytes = collected.reduce(0) { $0 + $1.buffer.readableBytes }
        if collected.count >= batch || maxBytes.map({ collectedBytes >= $0 }) == true {
            return parse(collected)
        }

        // A cancelled caller will not read what a new pull delivers; on an
        // explicit-ack consumer those messages would sit out their ack wait.
        if Task.isCancelled {
            return parse(collected)
        }

        let wanted = batch - collected.count
        let remainingBytes = maxBytes.map { max(1, $0 - collectedBytes) }
        let request = NextMessageRequest(
            batch: wanted,
            maxBytes: remainingBytes,
            expires: expires.nanoseconds
        )
        let payload = try context.encode(request)
        let reply = inbox.beginPull(wanted: wanted)

        do {
            try await context.natsClient.publish(
                context.consumerNextSubject(stream: streamName, consumer: name),
                payload: payload,
                reply: reply
            )
        } catch {
            _ = inbox.endPull()
            if !collected.isEmpty {
                return parse(collected)
            }
            throw JetStreamError.pullFailed(error.description)
        }

        // Wait a little past the server's expiry so that, normally, the
        // server's own 408 ends the pull: a message it delivers just before
        // expiring then arrives ahead of the status and is returned by this
        // fetch, instead of the fetch coming back empty with the message
        // following behind it.
        let grace = min(expires / 10, Self.maxExpiryGrace)
        await inbox.waitForPull(until: ContinuousClock.now.advanced(by: expires + grace))

        let more = inbox.take(upTo: wanted, maxBytes: remainingBytes)
        collected += more
        collectedBytes += more.reduce(0) { $0 + $1.buffer.readableBytes }
        let status = inbox.endPull()

        if inbox.isClosed {
            self.inbox = nil
            if collected.isEmpty {
                throw JetStreamError.notConnected
            }
        }

        if let status, let error = pullError(for: status, maxBytes: maxBytes, collectedAny: !collected.isEmpty) {
            if collected.isEmpty {
                throw error
            }
            deferredError = error
        }

        return parse(collected)
    }

    /// Get the next message (convenience for fetch with batch=1)
    public func next(maxWait: Duration? = nil) async throws(JetStreamError) -> JetStreamMessage? {
        let messages = try await fetch(batch: 1, maxWait: maxWait)
        return messages.first
    }

    /// Create an async stream of messages
    public func messages(
        batchSize: Int = 1,
        maxWait: Duration = .seconds(30)
    ) -> AsyncThrowingStream<JetStreamMessage, Error> {
        AsyncThrowingStream { continuation in
            Task {
                while !Task.isCancelled {
                    do {
                        let messages = try await self.fetch(batch: batchSize, maxWait: maxWait)
                        for message in messages {
                            continuation.yield(message)
                        }
                        if messages.isEmpty {
                            // Small delay before next fetch to avoid tight loop
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Create an iterator for consuming messages
    public func iterate(
        batchSize: Int = 1,
        maxWait: Duration = .seconds(30)
    ) -> MessageIterator {
        MessageIterator(consumer: self, batchSize: batchSize, maxWait: maxWait)
    }

    // MARK: - Internals

    private func openInbox() async throws(JetStreamError) -> PullInbox {
        if let inbox, !inbox.isClosed {
            return inbox
        }
        let opened = try await PullInbox.open(client: context.natsClient)
        inbox = opened
        return opened
    }

    private func parse(_ messages: [NatsMessage]) -> [JetStreamMessage] {
        messages.compactMap { message in
            // Anything that is not a JetStream delivery (no `$JS.ACK` reply)
            // is not a message for this consumer.
            try? JetStreamMessage.parse(message, context: context, stream: streamName, consumer: name)
        }
    }

    /// Upper bound on how long a fetch waits past the server's expiry.
    private static let maxExpiryGrace: Duration = .milliseconds(250)

    /// What a pull's status reply means for the caller, or nil when it is an
    /// ordinary end of a pull.
    private func pullError(for status: PullInbox.Status, maxBytes: Int?, collectedAny: Bool) -> JetStreamError? {
        switch status.code {
        case 404, 408:
            // No messages / request expired: the normal ends of a pull.
            return nil
        case 503:
            // No responders: JetStream is not answering, typically while a
            // broker restarts. Kept as an empty batch, as before — callers
            // tell "consumer forgotten" from "not back yet" by asking for the
            // consumer, and an error here would end their watch instead.
            return nil
        case 409:
            let description = status.description.lowercased()
            if description.contains("message size exceeds maxbytes") {
                // Also how the server ends a pull that filled its byte budget,
                // which is an error only when nothing at all fitted.
                return collectedAny ? nil : .messageExceedsMaxBytes(maxBytes: maxBytes ?? 0)
            }
            if description.contains("consumer deleted") {
                return .consumerNotFound(stream: streamName, consumer: name)
            }
            if description.contains("leadership change") {
                // Transient: the next pull goes to the new leader.
                return nil
            }
            return .pullFailed("\(status.code) \(status.description)")
        default:
            return status.code >= 400 ? .pullFailed("\(status.code) \(status.description)") : nil
        }
    }

    private func acquireFetch() async {
        if !fetching {
            fetching = true
            return
        }
        await withCheckedContinuation { fetchWaiters.append($0) }
    }

    private func releaseFetch() {
        if fetchWaiters.isEmpty {
            fetching = false
        } else {
            fetchWaiters.removeFirst().resume()
        }
    }
}

extension Duration {
    /// Whole nanoseconds, as the JetStream API expects durations.
    var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}

// MARK: - Message Iterator

/// An iterator for consuming JetStream messages
public struct MessageIterator: AsyncIteratorProtocol, AsyncSequence {
    public typealias Element = JetStreamMessage

    private let consumer: Consumer
    private let batchSize: Int
    private let maxWait: Duration
    private var buffer: [JetStreamMessage] = []

    init(consumer: Consumer, batchSize: Int, maxWait: Duration) {
        self.consumer = consumer
        self.batchSize = batchSize
        self.maxWait = maxWait
    }

    public mutating func next() async throws -> JetStreamMessage? {
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }

        let messages = try await consumer.fetch(batch: batchSize, maxWait: maxWait)
        if messages.isEmpty {
            return nil
        }

        buffer = Array(messages.dropFirst())
        return messages.first
    }

    public func makeAsyncIterator() -> MessageIterator {
        self
    }
}
