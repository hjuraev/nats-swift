// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import Synchronization

/// The inbox a `Consumer` pulls into, subscribed once and reused by every fetch.
///
/// A fetch used to subscribe a fresh inbox, publish the pull, and unsubscribe
/// when it returned — a SUB/UNSUB pair per fetch. Worse than the cost, the
/// unsubscribe fired at `expires`, the same moment the server could still be
/// delivering: messages that landed after it were silently discarded, and on an
/// `ackPolicy: .none` consumer (every KV listing and watch) that is loss.
///
/// Here one subscription on `<prefix>.*` lives as long as the consumer handle,
/// and each pull uses its own reply subject under it:
///
/// - **Messages** arrive on their stream subject, not the reply subject, so
///   they cannot be attributed to a pull. They are buffered and any fetch may
///   take them — a message delivered after its fetch gave up is picked up by
///   the next one instead of being lost.
/// - **Status replies** (404, 408, 409) arrive on the reply subject of the pull
///   they end. Only the current pull's status counts; a late 408 from a pull
///   that already gave up is ignored rather than ending the next fetch empty.
///
/// Messages are handed over inline on the client's inbound path, so a fetch
/// wakes once per batch rather than once per message.
final class PullInbox: Sendable {
    /// A status reply that ended a pull.
    struct Status: Sendable {
        let code: Int
        let description: String
    }

    private struct State {
        var buffered: [NatsMessage] = []
        var head = 0
        var bufferedBytes = 0
        var sid: String?
        var pulls: UInt64 = 0
        var currentReply: String?
        var wanted = 0
        var status: Status?
        var waiter: CheckedContinuation<Void, Never>?
        var closed = false

        var bufferedCount: Int { buffered.count - head }

        func isReady(until deadline: ContinuousClock.Instant) -> Bool {
            closed || status != nil || bufferedCount >= wanted || ContinuousClock.now >= deadline
        }

        mutating func takeWaiter() -> CheckedContinuation<Void, Never>? {
            let waiter = self.waiter
            self.waiter = nil
            return waiter
        }
    }

    let prefix: String
    private let client: NatsClient
    private let state = Mutex(State())

    private init(client: NatsClient, prefix: String) {
        self.client = client
        self.prefix = prefix
    }

    /// Subscribe a new inbox on `client`.
    static func open(client: NatsClient) async throws(JetStreamError) -> PullInbox {
        let inbox = PullInbox(client: client, prefix: Subject.newInbox(prefix: client.configuredInboxPrefix))
        do {
            let sid = try await client.subscribe(
                "\(inbox.prefix).*",
                sink: .handler(
                    onMessage: { [weak inbox] message in inbox?.receive(message) },
                    onFinish: { [weak inbox] in inbox?.markClosed() }
                )
            )
            inbox.state.withLock { $0.sid = sid }
        } catch {
            throw JetStreamError.mapping(error, operation: "fetch", timeout: .zero)
        }
        return inbox
    }

    deinit {
        let sid = state.withLock { $0.closed ? nil : $0.sid }
        if let sid {
            let client = self.client
            Task { await client.unsubscribe(sid: sid) }
        }
    }

    /// Whether the subscription has ended (connection closed, or `close()`).
    var isClosed: Bool {
        state.withLock { $0.closed }
    }

    /// Unsubscribe. The inbox cannot be used afterwards.
    func close() async {
        let sid: String? = state.withLock { state in
            guard !state.closed else { return nil }
            return state.sid
        }
        markClosed()
        if let sid {
            await client.unsubscribe(sid: sid)
        }
    }

    // MARK: - Fetch side

    /// Take up to `count` buffered messages, stopping before `maxBytes` would
    /// be exceeded (always taking at least one).
    func take(upTo count: Int, maxBytes: Int?) -> [NatsMessage] {
        state.withLock { state in
            var taken: [NatsMessage] = []
            var bytes = 0
            while taken.count < count, state.head < state.buffered.count {
                let message = state.buffered[state.head]
                let size = Self.size(of: message)
                if let maxBytes, !taken.isEmpty, bytes + size > maxBytes {
                    break
                }
                taken.append(message)
                bytes += size
                state.buffered[state.head] = Self.placeholder
                state.head += 1
                state.bufferedBytes -= size
            }
            if state.head == state.buffered.count {
                state.buffered.removeAll(keepingCapacity: true)
                state.head = 0
            } else if state.head > 1024, state.head * 2 > state.buffered.count {
                state.buffered.removeFirst(state.head)
                state.head = 0
            }
            return taken
        }
    }

    /// Start a pull that waits for `wanted` messages. Returns its reply subject.
    func beginPull(wanted: Int) -> String {
        state.withLock { state in
            state.pulls += 1
            let reply = "\(prefix).\(state.pulls)"
            state.currentReply = reply
            state.wanted = wanted
            state.status = nil
            return reply
        }
    }

    /// End the current pull and return the status that ended it, if any.
    func endPull() -> Status? {
        state.withLock { state in
            let status = state.status
            state.currentReply = nil
            state.status = nil
            state.wanted = 0
            return status
        }
    }

    /// Suspend until the current pull has `wanted` messages buffered, has
    /// received its status, the inbox closes, `deadline` passes, or the task
    /// is cancelled — whichever comes first.
    func waitForPull(until deadline: ContinuousClock.Instant) async {
        let pull = state.withLock { $0.pulls }
        let timer = Task { [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                // Cancelled because the wait already ended. Waking here would
                // resume whichever pull is waiting by then — the next fetch —
                // and end it empty.
                return
            }
            self?.wake(pull: pull)
        }
        defer { timer.cancel() }

        // Re-checked after every resume, so a wake-up that does not belong to
        // this wait cannot end it early.
        while !Task.isCancelled && !isReady(until: deadline) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let ready = state.withLock { state -> Bool in
                        // Every wake-up source is re-checked under the lock
                        // that stores the waiter, so one that fired first is
                        // not lost.
                        if state.isReady(until: deadline) || Task.isCancelled {
                            return true
                        }
                        state.waiter = continuation
                        return false
                    }
                    if ready {
                        continuation.resume()
                    }
                }
            } onCancel: {
                self.wake(pull: pull)
            }
        }
    }

    private func isReady(until deadline: ContinuousClock.Instant) -> Bool {
        state.withLock { $0.isReady(until: deadline) }
    }

    // MARK: - Delivery side

    private func receive(_ message: NatsMessage) {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { state in
            guard !state.closed else { return nil }

            if let code = message.headers?.status, message.subject.hasPrefix(prefix) {
                // 100 is an idle heartbeat or flow control, not an end.
                guard code >= 200, message.subject == state.currentReply else {
                    return nil
                }
                state.status = Status(code: code, description: message.headers?.statusDescription ?? "")
                return state.takeWaiter()
            }

            state.buffered.append(message)
            state.bufferedBytes += Self.size(of: message)
            guard state.waiter != nil, state.bufferedCount >= state.wanted else {
                return nil
            }
            return state.takeWaiter()
        }
        waiter?.resume()
    }

    private func markClosed() {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { state in
            state.closed = true
            return state.takeWaiter()
        }
        waiter?.resume()
    }

    /// Resume the waiter if it is still waiting on `pull`.
    private func wake(pull: UInt64) {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { state in
            guard state.pulls == pull else { return nil }
            return state.takeWaiter()
        }
        waiter?.resume()
    }

    /// What a message counts against a pull's `max_bytes`.
    private static func size(of message: NatsMessage) -> Int {
        message.subject.utf8.count + (message.replyTo?.utf8.count ?? 0) + message.buffer.readableBytes
    }

    private static let placeholder = NatsMessage(subject: "", buffer: .init())
}
