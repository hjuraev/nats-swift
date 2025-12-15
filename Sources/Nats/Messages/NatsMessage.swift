// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import NIOCore

/// A message received from NATS
public struct NatsMessage: Sendable {
    /// The subject the message was published to
    public let subject: String

    /// Optional reply-to subject for request-reply pattern
    public let replyTo: String?

    /// Optional headers
    public let headers: NatsHeaders?

    /// Raw buffer containing the message payload (zero-copy)
    public let buffer: ByteBuffer

    /// Timestamp when the message was received
    public let timestamp: ContinuousClock.Instant

    /// Subscription ID that received this message
    internal let sid: String

    /// Initialize a new message with ByteBuffer (zero-copy)
    public init(
        subject: String,
        replyTo: String? = nil,
        headers: NatsHeaders? = nil,
        buffer: ByteBuffer,
        timestamp: ContinuousClock.Instant = .now,
        sid: String = ""
    ) {
        self.subject = subject
        self.replyTo = replyTo
        self.headers = headers
        self.buffer = buffer
        self.timestamp = timestamp
        self.sid = sid
    }

    /// Initialize a new message with Data (copies to ByteBuffer)
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
        self.buffer = ByteBuffer.from(payload)
        self.timestamp = timestamp
        self.sid = sid
    }

    // MARK: - Payload Access

    /// Get payload as Data (creates a copy)
    @inlinable
    public var payload: Data {
        buffer.getData() ?? Data()
    }

    /// Zero-copy access to readable bytes
    @inlinable
    public var readableBytesView: ByteBufferView {
        buffer.readableBytesView
    }

    /// Get payload as a UTF-8 string
    @inlinable
    public var string: String? {
        buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)
    }

    /// Get payload as a byte array (creates a copy)
    @inlinable
    public var bytes: [UInt8] {
        Array(buffer.readableBytesView)
    }

    /// Decode payload as JSON
    @inlinable
    public func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: payload)
    }

    /// Check if payload is empty
    @inlinable
    public var isEmpty: Bool {
        buffer.readableBytes == 0
    }

    /// Payload size in bytes
    @inlinable
    public var size: Int {
        buffer.readableBytes
    }

    // MARK: - Zero-Copy Access

    /// Access payload bytes without copying via closure
    @inlinable
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try buffer.withUnsafeReadableBytes(body)
    }

    // Note: Span support will be added when swift-nio adds ByteBuffer.span property
}

extension NatsMessage: CustomStringConvertible {
    public var description: String {
        let payloadPreview: String
        if let str = string {
            payloadPreview = str.count > 50 ? "\(str.prefix(50))..." : str
        } else {
            payloadPreview = "<\(buffer.readableBytes) bytes>"
        }
        return "NatsMessage(subject: \(subject), payload: \(payloadPreview))"
    }
}

extension NatsMessage: Equatable {
    public static func == (lhs: NatsMessage, rhs: NatsMessage) -> Bool {
        lhs.subject == rhs.subject &&
        lhs.replyTo == rhs.replyTo &&
        lhs.buffer == rhs.buffer &&
        lhs.headers == rhs.headers
    }
}

extension NatsMessage: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(subject)
        hasher.combine(replyTo)
        hasher.combine(buffer.readableBytesView)
    }
}
