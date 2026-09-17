// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import NIOCore

/// A JetStream message with acknowledgement capabilities
public struct JetStreamMessage: Sendable {
    /// The underlying NATS message
    public let message: NatsMessage

    /// JetStream metadata extracted from the reply subject
    public let metadata: MessageMetadata

    /// Context for sending acknowledgements
    private let context: JetStreamContext
    private let streamName: String
    private let consumerName: String

    /// Message subject
    public var subject: String { message.subject }

    /// Message payload (zero-copy access to buffer)
    public var payload: ByteBuffer { message.buffer }

    /// Zero-copy access to readable bytes
    public var readableBytesView: ByteBufferView { message.readableBytesView }

    /// Access payload bytes without copying via closure
    @inlinable
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try message.withUnsafeBytes(body)
    }

    /// Message headers
    public var headers: NatsHeaders? { message.headers }

    init(
        message: NatsMessage,
        metadata: MessageMetadata,
        context: JetStreamContext,
        stream: String,
        consumer: String
    ) {
        self.message = message
        self.metadata = metadata
        self.context = context
        self.streamName = stream
        self.consumerName = consumer
    }

    // MARK: - Acknowledgement Methods

    /// Acknowledge the message
    public func ack() async throws {
        guard let replyTo = message.replyTo else {
            throw JetStreamError.invalidAck("No reply subject for acknowledgement")
        }
        try await sendAck(replyTo, payload: AckType.ack.buffer)
    }

    /// Acknowledge the message and wait for confirmation
    public func ackSync() async throws {
        guard let replyTo = message.replyTo else {
            throw JetStreamError.invalidAck("No reply subject for acknowledgement")
        }
        // For sync ack, we need a response
        try await sendAckWithResponse(replyTo, payload: AckType.ack.buffer)
    }

    /// Negatively acknowledge the message (request redelivery)
    public func nak(delay: Duration? = nil) async throws {
        guard let replyTo = message.replyTo else {
            throw JetStreamError.invalidAck("No reply subject for acknowledgement")
        }

        let payload: ByteBuffer
        if let delay = delay {
            let nanos = Int64(delay.components.seconds * 1_000_000_000)
            var buffer = ByteBuffer()
            buffer.writeString("-NAK {\"delay\": \(nanos)}")
            payload = buffer
        } else {
            payload = AckType.nak.buffer
        }

        try await sendAck(replyTo, payload: payload)
    }

    /// Signal that processing is still in progress (extends ack deadline)
    public func inProgress() async throws {
        guard let replyTo = message.replyTo else {
            throw JetStreamError.invalidAck("No reply subject for acknowledgement")
        }
        try await sendAck(replyTo, payload: AckType.inProgress.buffer)
    }

    /// Terminate redelivery of this message
    public func term() async throws {
        guard let replyTo = message.replyTo else {
            throw JetStreamError.invalidAck("No reply subject for acknowledgement")
        }
        try await sendAck(replyTo, payload: AckType.term.buffer)
    }

    // MARK: - Internal

    private func sendAck(_ subject: String, payload: ByteBuffer) async throws {
        // Simple ack - publish without waiting for response
        _ = try await context.request(subject, payload: payload)
    }

    private func sendAckWithResponse(_ subject: String, payload: ByteBuffer) async throws {
        _ = try await context.request(subject, payload: payload)
    }

    // MARK: - Parsing

    static func parse(
        _ message: NatsMessage,
        context: JetStreamContext,
        stream: String,
        consumer: String
    ) throws -> JetStreamMessage {
        guard let replyTo = message.replyTo else {
            throw JetStreamError.invalidAck("Missing reply subject")
        }

        // Format: $JS.ACK.<stream>.<consumer>.<numDelivered>.<streamSeq>.<consumerSeq>.<timestamp>.<numPending>
        guard let ack = AckSubject(replyTo) else {
            throw JetStreamError.invalidAck("Invalid reply subject format: \(replyTo)")
        }

        let metadata = MessageMetadata(
            // The fetching consumer's own names, when the subject carries them
            // (it always does), rather than a fresh copy per message.
            stream: ack.string(ack.stream, in: replyTo, reusing: stream),
            consumer: ack.string(ack.consumer, in: replyTo, reusing: consumer),
            numDelivered: ack.numDelivered,
            streamSequence: ack.streamSequence,
            consumerSequence: ack.consumerSequence,
            timestamp: ack.timestampNanos.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000_000_000) } ?? Date(),
            numPending: ack.numPending
        )

        return JetStreamMessage(
            message: message,
            metadata: metadata,
            context: context,
            stream: stream,
            consumer: consumer
        )
    }
}

/// The fields of a JetStream ack subject, read in one pass over its bytes.
///
/// Replaces `split(separator: ".")`, which built nine substrings for every
/// message delivered to a consumer. Empty tokens are skipped and malformed
/// numbers read as 0, as with the split.
struct AckSubject {
    var stream: Range<String.Index>
    var consumer: Range<String.Index>
    var numDelivered: UInt64 = 0
    var streamSequence: UInt64 = 0
    var consumerSequence: UInt64 = 0
    var timestampNanos: Int64?
    var numPending: UInt64 = 0

    init?(_ subject: String) {
        let utf8 = subject.utf8
        let end = utf8.endIndex
        var index = utf8.startIndex
        var token = 0
        var stream: Range<String.Index>?
        var consumer: Range<String.Index>?

        while token < 9 {
            while index < end, utf8[index] == UInt8(ascii: ".") {
                index = utf8.index(after: index)
            }
            guard index < end else { break }

            let start = index
            var value: UInt64 = 0
            var digits = 0
            var numeric = true
            while index < end {
                let byte = utf8[index]
                if byte == UInt8(ascii: ".") { break }
                let digit = byte &- UInt8(ascii: "0")
                if digit < 10, digits < 19 {
                    value = value * 10 + UInt64(digit)
                    digits += 1
                } else {
                    numeric = false
                }
                index = utf8.index(after: index)
            }
            let number = numeric ? value : 0

            switch token {
            case 0:
                guard utf8[start..<index].elementsEqual("$JS".utf8) else { return nil }
            case 1:
                guard utf8[start..<index].elementsEqual("ACK".utf8) else { return nil }
            case 2: stream = start..<index
            case 3: consumer = start..<index
            case 4: numDelivered = number
            case 5: streamSequence = number
            case 6: consumerSequence = number
            case 7: timestampNanos = numeric ? Int64(exactly: value) : nil
            default: numPending = number
            }
            token += 1
        }

        guard token == 9, let stream, let consumer else { return nil }
        self.stream = stream
        self.consumer = consumer
    }

    /// The token at `range` as a string, returning `known` when it spells the
    /// same bytes.
    func string(_ range: Range<String.Index>, in subject: String, reusing known: String) -> String {
        subject.utf8[range].elementsEqual(known.utf8) ? known : String(subject[range])
    }
}

// MARK: - Message Metadata

/// Metadata for a JetStream message
public struct MessageMetadata: Sendable {
    /// Stream name
    public let stream: String

    /// Consumer name
    public let consumer: String

    /// Number of times this message has been delivered
    public let numDelivered: UInt64

    /// Sequence number in the stream
    public let streamSequence: UInt64

    /// Sequence number in the consumer
    public let consumerSequence: UInt64

    /// Timestamp when the message was stored
    public let timestamp: Date

    /// Number of messages pending for this consumer
    public let numPending: UInt64
}

// MARK: - Acknowledgement Types

enum AckType {
    case ack
    case nak
    case inProgress
    case term

    var buffer: ByteBuffer {
        var buf = ByteBuffer()
        switch self {
        case .ack:
            buf.writeString("+ACK")
        case .nak:
            buf.writeString("-NAK")
        case .inProgress:
            buf.writeString("+WPI")
        case .term:
            buf.writeString("+TERM")
        }
        return buf
    }
}
