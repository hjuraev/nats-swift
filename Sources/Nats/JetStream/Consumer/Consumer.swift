// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// A JetStream consumer handle
public actor Consumer {
    private let context: JetStreamContext
    private var _info: ConsumerInfo
    private let streamName: String

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
    }

    // MARK: - Pull Consumption

    /// Fetch a batch of messages
    public func fetch(
        batch: Int = 1,
        maxWait: Duration? = nil
    ) async throws(JetStreamError) -> [JetStreamMessage] {
        try await context.getNextMessage(
            stream: streamName,
            consumer: name,
            batch: batch,
            expires: maxWait
        )
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
