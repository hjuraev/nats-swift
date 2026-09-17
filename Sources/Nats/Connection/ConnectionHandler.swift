// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
@preconcurrency import NIOCore
import NIOPosix
import Logging

/// Handles NATS connection channel events
final class ConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ServerOp
    typealias OutboundOut = ClientOp

    /// Ping state for stale connection detection
    enum PingState: Sendable {
        case idle
        case awaitingPong
        case stale
    }

    private let logger: Logger
    private let onMessages: @Sendable ([ServerOp]) -> Void
    private let onClose: @Sendable (Error?) -> Void
    private let onOpen: @Sendable () -> Void

    private var pingState: PingState = .idle
    private var outstandingPings: Int = 0
    private var maxPingsOut: Int
    private var pingTask: RepeatedTask?
    private var channelContext: ChannelHandlerContext?

    /// Ops decoded during the current read, handed over together on
    /// `channelReadComplete`. Event-loop confined.
    private var inbound: [ServerOp] = []

    /// - Parameter onMessages: receives every decoded server op, in wire order,
    ///   one batch per socket read. Batching is what lets the client process a
    ///   burst of messages in one step instead of scheduling a task per message,
    ///   and delivering batches in order is what keeps a pull's terminal status
    ///   behind the messages that preceded it.
    init(
        logger: Logger,
        maxPingsOut: Int = 2,
        onMessages: @escaping @Sendable ([ServerOp]) -> Void,
        onOpen: @escaping @Sendable () -> Void,
        onClose: @escaping @Sendable (Error?) -> Void
    ) {
        self.logger = logger
        self.maxPingsOut = maxPingsOut
        self.onMessages = onMessages
        self.onOpen = onOpen
        self.onClose = onClose
    }

    // MARK: - ChannelInboundHandler

    func channelActive(context: ChannelHandlerContext) {
        logger.trace("Channel active")
        channelContext = context
        onOpen()
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.trace("Channel inactive")
        cancelPingTask()
        // Anything read but not yet handed over goes before the close event.
        forwardInbound()
        onClose(nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let op = unwrapInboundIn(data)

        switch op {
        case .ping:
            // Auto-respond to server PING with PONG
            logger.trace("Received PING, sending PONG")
            context.writeAndFlush(wrapOutboundOut(.pong), promise: nil)

        case .pong:
            // Reset ping state on PONG
            logger.trace("Received PONG")
            pingState = .idle
            outstandingPings = 0

        default:
            break
        }

        // Forward all messages to the client once the read completes.
        inbound.append(op)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        forwardInbound()
        context.fireChannelReadComplete()
    }

    private func forwardInbound() {
        guard !inbound.isEmpty else { return }
        let batch = inbound
        inbound.removeAll(keepingCapacity: true)
        onMessages(batch)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Channel error: \(error)")
        context.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        logger.trace("User inbound event: \(event)")
        context.fireUserInboundEventTriggered(event)
    }

    // MARK: - Ping Management

    /// Start the ping timer using the stored channel context
    func startPingTimer(interval: TimeAmount) {
        guard let context = channelContext else {
            logger.warning("Cannot start ping timer - no channel context")
            return
        }
        startPingTimer(context: context, interval: interval)
    }

    func startPingTimer(context: ChannelHandlerContext, interval: TimeAmount) {
        cancelPingTask()

        // Store context for use in the timer callback
        // This is safe because the closure runs on the same event loop as the context
        nonisolated(unsafe) let capturedContext = context

        pingTask = context.eventLoop.scheduleRepeatedTask(
            initialDelay: interval,
            delay: interval
        ) { [weak self] task in
            guard let self = self else {
                task.cancel()
                return
            }
            self.sendPing(context: capturedContext)
        }
    }

    func cancelPingTask() {
        pingTask?.cancel()
        pingTask = nil
    }

    private func sendPing(context: ChannelHandlerContext) {
        outstandingPings += 1

        if outstandingPings > maxPingsOut {
            logger.warning("Stale connection detected - too many outstanding pings: \(outstandingPings)")
            pingState = .stale
            context.close(promise: nil)
            return
        }

        pingState = .awaitingPong
        logger.trace("Sending PING (\(outstandingPings) outstanding)")
        context.writeAndFlush(wrapOutboundOut(.ping), promise: nil)
    }

    // MARK: - Write Operations

    func write(_ op: ClientOp, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(op), promise: promise)
        return promise.futureResult
    }
}
