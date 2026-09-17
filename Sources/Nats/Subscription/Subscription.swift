// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import Synchronization

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

/// Where a subscription's messages go.
enum SubscriptionSink: Sendable {
    /// A public `Subscription`, read through its async stream.
    case stream(AsyncStream<NatsMessage>.Continuation)

    /// An internal consumer that takes messages inline on the delivery path.
    ///
    /// For the client's own inboxes (request replies, pull consumers), which
    /// would otherwise pay a task wake-up per message to read their own stream.
    /// `onMessage` runs on the client's inbound path and must not block.
    case handler(onMessage: @Sendable (NatsMessage) -> Void, onFinish: @Sendable () -> Void)

    func yield(_ message: NatsMessage) {
        switch self {
        case .stream(let continuation):
            continuation.yield(message)
        case .handler(let onMessage, _):
            onMessage(message)
        }
    }

    func finish() {
        switch self {
        case .stream(let continuation):
            continuation.finish()
        case .handler(_, let onFinish):
            onFinish()
        }
    }
}

/// Manages active subscriptions for a client.
///
/// A lock-protected class rather than an actor. Every inbound message is
/// looked up here, and as an actor that lookup cost two executor hops per
/// message — measured as the largest single share of the client's per-message
/// cost. All operations are short and never suspend, so a lock is enough.
/// Sinks are always called outside the lock.
final class SubscriptionManager: Sendable {
    /// Internal subscription state
    struct SubscriptionState {
        let subject: String
        let queueGroup: String?
        let sink: SubscriptionSink
        var messageCount: Int = 0
        var maxMessages: Int?  // For auto-unsubscribe
        var isDraining: Bool = false  // True when unsubscribe has been initiated
    }

    private struct State {
        var subscriptions: [String: SubscriptionState] = [:]
        var drainingSubscriptions: Set<String> = []  // Track recently unsubscribed for in-flight messages
        var nextSid: UInt64 = 0
        var isClosed = false  // When true, all messages are silently discarded
    }

    private let state = Mutex(State())

    /// Generate a new subscription ID
    func generateSid() -> String {
        state.withLock { state in
            state.nextSid += 1
            return String(state.nextSid)
        }
    }

    /// Register a new subscription delivered through an async stream.
    func register(
        sid: String,
        subject: String,
        queueGroup: String?,
        continuation: AsyncStream<NatsMessage>.Continuation
    ) {
        register(sid: sid, subject: subject, queueGroup: queueGroup, sink: .stream(continuation))
    }

    /// Register a new subscription
    func register(sid: String, subject: String, queueGroup: String?, sink: SubscriptionSink) {
        state.withLock { state in
            // Remove from draining set if being reused
            state.drainingSubscriptions.remove(sid)
            state.subscriptions[sid] = SubscriptionState(
                subject: subject,
                queueGroup: queueGroup,
                sink: sink
            )
        }
    }

    /// Mark a subscription as draining (unsubscribe initiated, but may still receive in-flight messages)
    func markDraining(sid: String) {
        state.withLock { state in
            if state.subscriptions[sid] != nil {
                state.subscriptions[sid]?.isDraining = true
            }
        }
    }

    /// Unregister a subscription
    func unregister(sid: String) {
        let removed: SubscriptionState? = state.withLock { state in
            guard let removed = state.subscriptions.removeValue(forKey: sid) else { return nil }
            // Track as draining for a short period to handle in-flight messages
            state.drainingSubscriptions.insert(sid)
            return removed
        }
        guard let removed else { return }
        removed.sink.finish()
        scheduleDrainingCleanup(sid: sid)
    }

    /// Drop `sid` from the draining set once in-flight messages have had time to land.
    private func scheduleDrainingCleanup(sid: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.cleanupDraining(sid: sid)
        }
    }

    private func cleanupDraining(sid: String) {
        _ = state.withLock { state in
            state.drainingSubscriptions.remove(sid)
        }
    }

    /// Set auto-unsubscribe limit
    func setAutoUnsubscribe(sid: String, max: Int) {
        state.withLock { state in
            state.subscriptions[sid]?.maxMessages = max
        }
    }

    /// Check if a subscription is known (active or draining)
    func isKnown(sid: String) -> Bool {
        state.withLock { state in
            state.subscriptions[sid] != nil || state.drainingSubscriptions.contains(sid)
        }
    }

    /// Deliver a message to a subscription
    /// Returns true if delivered or if subscription is draining (to avoid warnings)
    /// Returns false only if subscription is completely unknown
    func deliver(sid: String, message: NatsMessage) -> Bool {
        enum Outcome {
            case unknown
            case discarded
            case deliver(SubscriptionSink, finishAfter: Bool)
        }

        let outcome: Outcome = state.withLock { state in
            // If manager is closed, silently discard all messages
            if state.isClosed {
                return .discarded
            }

            // Check if this is a draining subscription (in-flight messages are expected)
            if state.drainingSubscriptions.contains(sid) {
                // Silently discard - this is expected for in-flight messages
                return .discarded
            }

            guard var subscription = state.subscriptions[sid] else {
                return .unknown
            }

            // If subscription is draining, don't deliver new messages
            if subscription.isDraining {
                return .discarded
            }

            subscription.messageCount += 1

            // Check for auto-unsubscribe
            if let max = subscription.maxMessages, subscription.messageCount >= max {
                state.subscriptions.removeValue(forKey: sid)
                state.drainingSubscriptions.insert(sid)
                return .deliver(subscription.sink, finishAfter: true)
            }

            state.subscriptions[sid] = subscription
            return .deliver(subscription.sink, finishAfter: false)
        }

        switch outcome {
        case .unknown:
            return false
        case .discarded:
            return true
        case .deliver(let sink, let finishAfter):
            sink.yield(message)
            if finishAfter {
                sink.finish()
                scheduleDrainingCleanup(sid: sid)
            }
            return true
        }
    }

    /// Get all active subscriptions (for resubscription after a reconnect).
    ///
    /// `remainingMax` carries the number of messages the server should still
    /// deliver before auto-unsubscribing — i.e. the original limit minus what
    /// has already been delivered — or `nil` for subscriptions without a limit.
    func getAllSubscriptions() -> [(sid: String, subject: String, queueGroup: String?, remainingMax: Int?)] {
        state.withLock { state in
            state.subscriptions.compactMap { sid, subscription in
                guard !subscription.isDraining else { return nil }
                let remainingMax = subscription.maxMessages.map { max(0, $0 - subscription.messageCount) }
                return (sid, subscription.subject, subscription.queueGroup, remainingMax)
            }
        }
    }

    /// Finish all subscriptions (on disconnect)
    func finishAll() {
        let sinks: [SubscriptionSink] = state.withLock { state in
            // Move all active subscriptions to draining before clearing
            // This allows in-flight messages to be silently discarded
            for sid in state.subscriptions.keys {
                state.drainingSubscriptions.insert(sid)
            }
            let sinks = state.subscriptions.values.map(\.sink)
            state.subscriptions.removeAll()
            // Keep drainingSubscriptions populated to absorb in-flight messages
            // They will be cleaned up by their individual timeout tasks
            // Also mark as closed to reject all future messages silently
            state.isClosed = true
            return sinks
        }
        for sink in sinks {
            sink.finish()
        }
    }

    /// Clear the closed latch so this manager can serve a new connection.
    ///
    /// `finishAll()` sets `isClosed`, which makes `deliver` silently discard
    /// every message from then on. Nothing ever cleared it, so once a client had
    /// closed — or merely finished a drain — its subscription manager was dead
    /// for the lifetime of the process, and any subscription created afterwards
    /// received nothing while looking perfectly healthy.
    func reopen() {
        state.withLock { state in
            state.isClosed = false
            state.drainingSubscriptions.removeAll()
        }
    }

    /// Count of active subscriptions
    var count: Int {
        state.withLock { state in
            state.subscriptions.filter { !$0.value.isDraining }.count
        }
    }
}
