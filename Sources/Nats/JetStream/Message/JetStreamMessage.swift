// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

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

    /// Message payload
    public var payload: Data { message.payload }

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
        try await sendAck(replyTo, payload: AckType.ack.data)
    }

    /// Acknowledge the message and wait for confirmation
    public func ackSync() async throws {
        guard let replyTo = message.replyTo else {
            throw JetStreamError.invalidAck("No reply subject for acknowledgement")
        }
        // For sync ack, we need a response
        try await sendAckWithResponse(replyTo, payload: AckType.ack.data)
    }

    /// Negatively acknowledge the message (request redelivery)
    public func nak(delay: Duration? = nil) async throws {
        guard let replyTo = message.replyTo else {
            throw JetStreamError.invalidAck("No reply subject for acknowledgement")
        }

        let payload: Data
        if let delay = delay {
            let nanos = Int64(delay.components.seconds * 1_000_000_000)
            payload = "-NAK {\"delay\": \(nanos)}".data(using: .utf8)!
        } else {
            payload = AckType.nak.data
        }

        try await sendAck(replyTo, payload: payload)
    }

    /// Signal that processing is still in progress (extends ack deadline)
    public func inProgress() async throws {
        guard let replyTo = message.replyTo else {
            throw JetStreamError.invalidAck("No reply subject for acknowledgement")
        }
        try await sendAck(replyTo, payload: AckType.inProgress.data)
    }

    /// Terminate redelivery of this message
    public func term() async throws {
        guard let replyTo = message.replyTo else {
            throw JetStreamError.invalidAck("No reply subject for acknowledgement")
        }
        try await sendAck(replyTo, payload: AckType.term.data)
    }

    // MARK: - Internal

    private func sendAck(_ subject: String, payload: Data) async throws {
        // Simple ack - publish without waiting for response
        _ = try await context.request(subject, payload: payload)
    }

    private func sendAckWithResponse(_ subject: String, payload: Data) async throws {
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

        // Parse metadata from reply subject
        // Format: $JS.ACK.<stream>.<consumer>.<numDelivered>.<streamSeq>.<consumerSeq>.<timestamp>.<numPending>
        let parts = replyTo.split(separator: ".")

        guard parts.count >= 9,
              parts[0] == "$JS",
              parts[1] == "ACK" else {
            throw JetStreamError.invalidAck("Invalid reply subject format: \(replyTo)")
        }

        let metadata = MessageMetadata(
            stream: String(parts[2]),
            consumer: String(parts[3]),
            numDelivered: UInt64(parts[4]) ?? 0,
            streamSequence: UInt64(parts[5]) ?? 0,
            consumerSequence: UInt64(parts[6]) ?? 0,
            timestamp: parseTimestamp(String(parts[7])),
            numPending: UInt64(parts[8]) ?? 0
        )

        return JetStreamMessage(
            message: message,
            metadata: metadata,
            context: context,
            stream: stream,
            consumer: consumer
        )
    }

    private static func parseTimestamp(_ str: String) -> Date {
        // Timestamp is in nanoseconds since Unix epoch
        guard let nanos = Int64(str) else {
            return Date()
        }
        let seconds = TimeInterval(nanos) / 1_000_000_000
        return Date(timeIntervalSince1970: seconds)
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

    var data: Data {
        switch self {
        case .ack:
            return "+ACK".data(using: .utf8)!
        case .nak:
            return "-NAK".data(using: .utf8)!
        case .inProgress:
            return "+WPI".data(using: .utf8)!
        case .term:
            return "+TERM".data(using: .utf8)!
        }
    }
}
