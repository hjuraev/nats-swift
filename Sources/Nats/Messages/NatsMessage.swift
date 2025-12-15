// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// A message received from NATS
public struct NatsMessage: Sendable {
    /// The subject the message was published to
    public let subject: String

    /// Optional reply-to subject for request-reply pattern
    public let replyTo: String?

    /// Optional headers
    public let headers: NatsHeaders?

    /// Message payload as raw bytes
    public let payload: Data

    /// Timestamp when the message was received
    public let timestamp: ContinuousClock.Instant

    /// Subscription ID that received this message
    internal let sid: String

    /// Initialize a new message
    public init(
        subject: String,
        replyTo: String? = nil,
        headers: NatsHeaders? = nil,
        payload: Data,
        timestamp: ContinuousClock.Instant = .now,
        sid: String = ""
    ) {
        self.subject = subject
        self.replyTo = replyTo
        self.headers = headers
        self.payload = payload
        self.timestamp = timestamp
        self.sid = sid
    }

    // MARK: - Payload Access

    /// Get payload as a UTF-8 string
    @inlinable
    public var string: String? {
        String(data: payload, encoding: .utf8)
    }

    /// Get payload as a byte array
    @inlinable
    public var bytes: [UInt8] {
        Array(payload)
    }

    /// Decode payload as JSON
    @inlinable
    public func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: payload)
    }

    /// Check if payload is empty
    @inlinable
    public var isEmpty: Bool {
        payload.isEmpty
    }

    /// Payload size in bytes
    @inlinable
    public var size: Int {
        payload.count
    }
}

extension NatsMessage: CustomStringConvertible {
    public var description: String {
        let payloadPreview: String
        if let str = string {
            payloadPreview = str.count > 50 ? "\(str.prefix(50))..." : str
        } else {
            payloadPreview = "<\(payload.count) bytes>"
        }
        return "NatsMessage(subject: \(subject), payload: \(payloadPreview))"
    }
}

extension NatsMessage: Equatable {
    public static func == (lhs: NatsMessage, rhs: NatsMessage) -> Bool {
        lhs.subject == rhs.subject &&
        lhs.replyTo == rhs.replyTo &&
        lhs.payload == rhs.payload &&
        lhs.headers == rhs.headers
    }
}

extension NatsMessage: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(subject)
        hasher.combine(replyTo)
        hasher.combine(payload)
    }
}
