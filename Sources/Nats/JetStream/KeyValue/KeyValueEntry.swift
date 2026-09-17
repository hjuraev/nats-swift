// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import NIOCore

/// The type of operation that produced a KV entry
public enum KeyValueOperation: String, Sendable {
    case put = "PUT"
    case delete = "DEL"
    case purge = "PURGE"
}

/// A single entry in a Key-Value bucket
public struct KeyValueEntry: Sendable {
    /// Bucket name
    public let bucket: String

    /// Key name
    public let key: String

    /// Entry value
    public let value: ByteBuffer

    /// Stream sequence number (revision)
    public let revision: UInt64

    /// When the entry was created/stored
    public let created: Date

    /// The operation that produced this entry
    public let operation: KeyValueOperation

    /// Number of pending entries for a watcher (0 for direct gets)
    public let delta: UInt64

    /// Value as a UTF-8 string
    public var stringValue: String? {
        value.getString(at: value.readerIndex, length: value.readableBytes)
    }

    /// Parse a KV entry from a Direct Get response
    static func fromDirectGet(_ message: NatsMessage, bucket: String) -> KeyValueEntry? {
        guard let headers = message.headers else { return nil }

        // Parse sequence
        guard let seqStr = headers[NatsHeaders.Keys.natsSequence],
              let seq = UInt64(seqStr) else { return nil }

        // Parse subject to extract key
        guard let subject = headers[NatsHeaders.Keys.natsSubject] else { return nil }
        let keyPrefix = "$KV.\(bucket)."
        guard subject.hasPrefix(keyPrefix) else { return nil }
        let key = String(subject.dropFirst(keyPrefix.count))

        // Parse timestamp
        let created: Date
        if let tsStr = headers[NatsHeaders.Keys.natsTimeStamp] {
            created = parseNatsTimestamp(tsStr)
        } else {
            created = Date()
        }

        // Parse operation from KV-Operation header
        let operation = parseOperation(from: headers)

        return KeyValueEntry(
            bucket: bucket,
            key: key,
            value: message.buffer,
            revision: seq,
            created: created,
            operation: operation,
            delta: 0
        )
    }

    /// Parse a KV entry from a consumer message
    static func fromConsumerMessage(_ message: JetStreamMessage, bucket: String) -> KeyValueEntry? {
        fromConsumerMessage(message, bucket: bucket, keyPrefix: "$KV.\(bucket).")
    }

    /// Parse a KV entry from a consumer message, with the bucket's key prefix
    /// (`$KV.<bucket>.`) built once by a caller parsing many messages.
    static func fromConsumerMessage(_ message: JetStreamMessage, bucket: String, keyPrefix: String) -> KeyValueEntry? {
        let subject = message.subject
        guard subject.hasPrefix(keyPrefix) else { return nil }
        let key = String(subject.dropFirst(keyPrefix.count))

        // Parse operation from headers
        let operation = parseOperation(from: message.headers)

        return KeyValueEntry(
            bucket: bucket,
            key: key,
            value: message.payload,
            revision: message.metadata.streamSequence,
            created: message.metadata.timestamp,
            operation: operation,
            delta: message.metadata.numPending
        )
    }

    /// Parse a KV entry from a raw NatsMessage (for watch consumers)
    static func fromRawMessage(_ message: NatsMessage, bucket: String) -> KeyValueEntry? {
        guard let replyTo = message.replyTo else { return nil }

        let subject = message.subject
        let keyPrefix = "$KV.\(bucket)."
        guard subject.hasPrefix(keyPrefix) else { return nil }
        let key = String(subject.dropFirst(keyPrefix.count))

        // Parse metadata from reply subject
        // Format: $JS.ACK.<stream>.<consumer>.<numDelivered>.<streamSeq>.<consumerSeq>.<timestamp>.<numPending>
        let parts = replyTo.split(separator: ".")
        guard parts.count >= 9 else { return nil }

        let streamSeq = UInt64(parts[5]) ?? 0
        let numPending = UInt64(parts[8]) ?? 0

        let timestamp: Date
        if let nanos = Int64(String(parts[7])) {
            let seconds = TimeInterval(nanos) / 1_000_000_000
            timestamp = Date(timeIntervalSince1970: seconds)
        } else {
            timestamp = Date()
        }

        // Parse operation from headers
        let operation = parseOperation(from: message.headers)

        return KeyValueEntry(
            bucket: bucket,
            key: key,
            value: message.buffer,
            revision: streamSeq,
            created: timestamp,
            operation: operation,
            delta: numPending
        )
    }

    private static func parseOperation(from headers: NatsHeaders?) -> KeyValueOperation {
        guard let headers = headers else { return .put }

        // Check KV-Operation header first
        if let opStr = headers[NatsHeaders.Keys.kvOperation] {
            switch opStr.uppercased() {
            case "DEL":
                return .delete
            case "PURGE":
                return .purge
            default:
                break
            }
        }

        // Check Nats-Marker-Reason header (for server-generated markers)
        if let reason = headers[NatsHeaders.Keys.natsMarkerReason] {
            switch reason {
            case "MaxAge", "Purge":
                return .purge
            case "Remove":
                return .delete
            default:
                break
            }
        }

        return .put
    }

    private static func parseNatsTimestamp(_ str: String) -> Date {
        RFC3339.date(from: str) ?? Date()
    }
}

/// Request body for Direct Get API
struct DirectGetRequest: Codable {
    let seq: UInt64?
    let lastBySubject: String?

    init(seq: UInt64? = nil, lastBySubject: String? = nil) {
        self.seq = seq
        self.lastBySubject = lastBySubject
    }

    enum CodingKeys: String, CodingKey {
        case seq
        case lastBySubject = "last_by_subj"
    }
}
