// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// A subscription to a NATS subject that delivers messages as an AsyncSequence
public struct Subscription: AsyncSequence, Sendable {
    public typealias Element = NatsMessage

    /// The subject this subscription is listening on
    public let subject: String

    /// Optional queue group for load balancing
    public let queueGroup: String?

    /// Internal subscription ID
    internal let sid: String

    /// The async stream that delivers messages
    private let stream: AsyncStream<NatsMessage>

    /// Callback to unsubscribe
    private let unsubscribeCallback: @Sendable () async -> Void

    /// Callback for auto-unsubscribe after N messages
    private let autoUnsubscribeCallback: @Sendable (Int) async -> Void

    internal init(
        subject: String,
        queueGroup: String?,
        sid: String,
        stream: AsyncStream<NatsMessage>,
        unsubscribe: @escaping @Sendable () async -> Void,
        autoUnsubscribe: @escaping @Sendable (Int) async -> Void
    ) {
        self.subject = subject
        self.queueGroup = queueGroup
        self.sid = sid
        self.stream = stream
        self.unsubscribeCallback = unsubscribe
        self.autoUnsubscribeCallback = autoUnsubscribe
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncStream<NatsMessage>.AsyncIterator

        public mutating func next() async -> NatsMessage? {
            await iterator.next()
        }
    }

    /// Unsubscribe from the subject immediately
    public func unsubscribe() async {
        await unsubscribeCallback()
    }

    /// Unsubscribe after receiving the specified number of messages
    public func unsubscribe(after maxMessages: Int) async {
        await autoUnsubscribeCallback(maxMessages)
    }

    /// Drain the subscription (finish receiving pending messages then unsubscribe)
    public func drain() async {
        await unsubscribeCallback()
    }
}

// MARK: - Subscription Manager

/// Manages active subscriptions for a client
actor SubscriptionManager {
    /// Internal subscription state
    struct SubscriptionState {
        let subject: String
        let queueGroup: String?
        let continuation: AsyncStream<NatsMessage>.Continuation
        var messageCount: Int = 0
        var maxMessages: Int?  // For auto-unsubscribe
        var isDraining: Bool = false  // True when unsubscribe has been initiated
    }

    private var subscriptions: [String: SubscriptionState] = [:]
    private var drainingSubscriptions: Set<String> = []  // Track recently unsubscribed for in-flight messages
    private var nextSid: UInt64 = 0
    private var isClosed = false  // When true, all messages are silently discarded

    /// Generate a new subscription ID
    func generateSid() -> String {
        nextSid += 1
        return String(nextSid)
    }

    /// Register a new subscription
    func register(
        sid: String,
        subject: String,
        queueGroup: String?,
        continuation: AsyncStream<NatsMessage>.Continuation
    ) {
        // Remove from draining set if being reused
        drainingSubscriptions.remove(sid)
        subscriptions[sid] = SubscriptionState(
            subject: subject,
            queueGroup: queueGroup,
            continuation: continuation
        )
    }

    /// Mark a subscription as draining (unsubscribe initiated, but may still receive in-flight messages)
    func markDraining(sid: String) {
        if subscriptions[sid] != nil {
            subscriptions[sid]?.isDraining = true
        }
    }

    /// Unregister a subscription
    func unregister(sid: String) {
        if let state = subscriptions.removeValue(forKey: sid) {
            state.continuation.finish()
            // Track as draining for a short period to handle in-flight messages
            drainingSubscriptions.insert(sid)
            // Schedule cleanup of draining set
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                await self?.cleanupDraining(sid: sid)
            }
        }
    }

    /// Remove from draining set (async to allow actor-isolated access from Task)
    private func cleanupDraining(sid: String) async {
        drainingSubscriptions.remove(sid)
    }

    /// Set auto-unsubscribe limit
    func setAutoUnsubscribe(sid: String, max: Int) {
        subscriptions[sid]?.maxMessages = max
    }

    /// Check if a subscription is known (active or draining)
    func isKnown(sid: String) -> Bool {
        subscriptions[sid] != nil || drainingSubscriptions.contains(sid)
    }

    /// Deliver a message to a subscription
    /// Returns true if delivered or if subscription is draining (to avoid warnings)
    /// Returns false only if subscription is completely unknown
    func deliver(sid: String, message: NatsMessage) -> Bool {
        // If manager is closed, silently discard all messages
        if isClosed {
            return true
        }

        // Check if this is a draining subscription (in-flight messages are expected)
        if drainingSubscriptions.contains(sid) {
            // Silently discard - this is expected for in-flight messages
            return true
        }

        guard var state = subscriptions[sid] else {
            return false
        }

        // If subscription is draining, don't deliver new messages
        if state.isDraining {
            return true
        }

        state.messageCount += 1
        state.continuation.yield(message)

        // Check for auto-unsubscribe
        if let max = state.maxMessages, state.messageCount >= max {
            state.continuation.finish()
            subscriptions.removeValue(forKey: sid)
            drainingSubscriptions.insert(sid)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                await self?.cleanupDraining(sid: sid)
            }
            return true
        }

        subscriptions[sid] = state
        return true
    }

    /// Get all active subscription IDs and subjects (for resubscription)
    func getAllSubscriptions() -> [(sid: String, subject: String, queueGroup: String?)] {
        subscriptions.compactMap { sid, state in
            state.isDraining ? nil : (sid, state.subject, state.queueGroup)
        }
    }

    /// Finish all subscriptions (on disconnect)
    func finishAll() {
        // Move all active subscriptions to draining before clearing
        // This allows in-flight messages to be silently discarded
        for sid in subscriptions.keys {
            drainingSubscriptions.insert(sid)
        }
        for state in subscriptions.values {
            state.continuation.finish()
        }
        subscriptions.removeAll()
        // Keep drainingSubscriptions populated to absorb in-flight messages
        // They will be cleaned up by their individual timeout tasks
        // Also mark as closed to reject all future messages silently
        isClosed = true
    }

    /// Count of active subscriptions
    var count: Int {
        subscriptions.filter { !$0.value.isDraining }.count
    }
}
