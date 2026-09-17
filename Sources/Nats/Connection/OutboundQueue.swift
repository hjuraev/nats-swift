// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
@preconcurrency import NIOCore
import Synchronization

/// Frames waiting to be written to one channel, flushed in batches.
///
/// Writing each frame with its own `writeAndFlush` and awaiting it cost an
/// event-loop round trip and a socket write per operation: a sequential publish
/// loop ran at ~9,000 frames/s on Linux, far below what the server accepts.
/// Here a caller appends its frame under a lock and returns; the first frame of
/// a batch schedules one event-loop task, which writes everything queued by the
/// time it runs and flushes once.
///
/// **What a successful enqueue means.** The frame is queued in order for this
/// connection, not yet on the socket — the same contract as the Go, Rust and
/// Java clients. A write that later fails or misses `writeTimeout` records the
/// failure and closes the connection; later operations on this queue report
/// it. Frames still queued when the connection goes are dropped — a reconnect
/// builds a new queue and does not replay them.
///
/// **Bounds.** The queue itself is bounded by `maxQueuedBytes`; beyond that,
/// and whenever the channel reports itself unwritable, `NatsClient` holds the
/// caller back (see `isSaturated`). A flush that does not reach the socket
/// within `writeTimeout` abandons the connection: bytes already handed to the
/// channel cannot be recalled, and a stream carrying half a frame cannot be
/// reused.
final class OutboundQueue: Sendable {
    private struct State {
        var frames: [(op: ClientOp, written: EventLoopPromise<Void>?)] = []
        var queuedBytes = 0
        var flushScheduled = false
        var failure: (any Error)?
    }

    let channel: Channel
    private let state = Mutex(State())
    private let writeTimeout: Duration
    private let maxQueuedBytes: Int
    private let onAbandon: @Sendable (Channel, any Error) -> Void

    /// - Parameters:
    ///   - maxQueuedBytes: queue size above which callers are held back until
    ///     the event loop has taken the frames.
    ///   - onAbandon: called on the event loop when a flush misses its deadline;
    ///     expected to close the channel.
    init(
        channel: Channel,
        writeTimeout: Duration,
        maxQueuedBytes: Int,
        onAbandon: @escaping @Sendable (Channel, any Error) -> Void
    ) {
        self.channel = channel
        self.writeTimeout = writeTimeout
        self.maxQueuedBytes = maxQueuedBytes
        self.onAbandon = onAbandon
    }

    /// The failure that ended this queue, if any.
    var failure: (any Error)? {
        state.withLock { $0.failure }
    }

    /// Whether a caller should wait before queuing more: the channel is not
    /// draining, or frames the event loop has not yet taken exceed the bound.
    var isSaturated: Bool {
        if !channel.isWritable { return true }
        return state.withLock { $0.queuedBytes >= maxQueuedBytes }
    }

    /// Queue `op` for the channel without waiting for the socket.
    ///
    /// Throws the failure that ended the queue, if it has ended.
    func enqueue(_ op: ClientOp) throws {
        try enqueue(op, written: nil)
    }

    /// Queue `op` and wait until it has been written to the socket.
    ///
    /// For the few frames whose delivery the caller has to know about before
    /// going on — CONNECT above all: over TLS its write completes only once the
    /// handshake has, and that is how a stalled handshake is noticed. Bounded
    /// by the flush deadline, and by the caller's own deadline through closing
    /// the channel.
    func enqueueAndWait(_ op: ClientOp) async throws {
        let written = channel.eventLoop.makePromise(of: Void.self)
        do {
            try enqueue(op, written: written)
        } catch {
            written.fail(error)
        }
        try await written.futureResult.get()
    }

    /// Give frames already queued a bounded chance to reach the socket.
    ///
    /// For `close()`: a publish returns once queued, so closing straight after
    /// one would otherwise drop it. Queues a PING behind them — writes complete
    /// in order — and returns when it is written or `limit` passes, whichever
    /// is first. Never fails the queue or the channel.
    func flushQueued(within limit: Duration) async {
        guard channel.isActive, failure == nil else { return }

        let eventLoop = channel.eventLoop
        let done = eventLoop.makePromise(of: Void.self)
        let written = eventLoop.makePromise(of: Void.self)
        let settled = SettleFlag()
        written.futureResult.whenComplete { _ in
            if settled.claim() { done.succeed(()) }
        }
        let timer = eventLoop.scheduleTask(in: TimeAmount(limit)) {
            if settled.claim() { done.succeed(()) }
        }

        do {
            try enqueue(.ping, written: written)
        } catch {
            written.fail(error)
        }
        try? await done.futureResult.get()
        timer.cancel()
    }

    private func enqueue(_ op: ClientOp, written: EventLoopPromise<Void>?) throws {
        let scheduleFlush: Bool = try state.withLock { state in
            if let failure = state.failure {
                throw failure
            }
            state.frames.append((op, written))
            state.queuedBytes += op.estimatedSize
            if state.flushScheduled {
                return false
            }
            state.flushScheduled = true
            return true
        }

        if scheduleFlush {
            channel.eventLoop.execute { self.flush() }
        }
    }

    /// Record `error` as the reason this queue ended. First failure wins.
    func fail(_ error: any Error) {
        let dropped = state.withLock { state in
            if state.failure == nil {
                state.failure = error
            }
            let dropped = state.frames
            state.frames.removeAll()
            state.queuedBytes = 0
            return dropped
        }
        for frame in dropped {
            frame.written?.fail(error)
        }
    }

    /// Write everything queued so far and flush once. Runs on the event loop.
    private func flush() {
        let frames: [(op: ClientOp, written: EventLoopPromise<Void>?)] = state.withLock { state in
            let frames = state.frames
            state.frames.removeAll(keepingCapacity: true)
            state.queuedBytes = 0
            state.flushScheduled = false
            return frames
        }
        guard let last = frames.last else { return }

        guard channel.isActive else {
            for frame in frames {
                frame.written?.fail(ConnectionError.closed)
            }
            fail(ConnectionError.closed)
            return
        }

        for frame in frames.dropLast() {
            channel.write(frame.op, promise: frame.written)
        }

        // Writes complete in order, so the last frame's promise settles the batch.
        let written = channel.eventLoop.makePromise(of: Void.self)
        if let callerPromise = last.written {
            written.futureResult.cascade(to: callerPromise)
        }
        channel.writeAndFlush(last.op, promise: written)

        let timeout = writeTimeout
        let settled = SettleFlag()
        let deadline = channel.eventLoop.scheduleTask(in: TimeAmount(timeout)) { [self] in
            guard settled.claim() else { return }
            let error = ConnectionError.writeTimedOut(after: timeout)
            fail(error)
            onAbandon(channel, error)
        }
        written.futureResult.whenComplete { [self] result in
            guard settled.claim() else { return }
            deadline.cancel()
            if case .failure(let error) = result {
                fail(error)
            }
        }
    }

    /// Settle-once guard shared by a flush's completion and its deadline. Both
    /// run on the same event loop; the lock only satisfies `Sendable`.
    private final class SettleFlag: Sendable {
        private let settled = Mutex(false)

        /// Returns true to exactly one caller.
        func claim() -> Bool {
            settled.withLock { settled in
                if settled { return false }
                settled = true
                return true
            }
        }
    }
}

extension ClientOp {
    /// Approximate encoded size, for bounding the outbound queue. Exactness
    /// does not matter; payloads dominate.
    var estimatedSize: Int {
        switch self {
        case .publish(let subject, let reply, _, let payload):
            return subject.utf8.count + (reply?.utf8.count ?? 0) + payload.readableBytes + 32
        case .subscribe(_, let subject, let queue):
            return subject.utf8.count + (queue?.utf8.count ?? 0) + 16
        case .connect:
            return 256
        case .ping, .pong, .unsubscribe:
            return 16
        }
    }
}
