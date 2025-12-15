// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Acknowledgement returned after publishing to JetStream
public struct PubAck: Codable, Sendable {
    /// Stream the message was published to
    public let stream: String

    /// Sequence number assigned to the message
    public let seq: UInt64

    /// Whether this was a duplicate message
    public let duplicate: Bool?

    /// Domain the stream is in
    public let domain: String?

    enum CodingKeys: String, CodingKey {
        case stream
        case seq
        case duplicate
        case domain
    }
}

/// Options for publishing to JetStream
public struct PublishOptions: Sendable {
    /// Message ID for duplicate detection
    public var messageID: String?

    /// Expected stream name (for validation)
    public var expectedStream: String?

    /// Expected last message ID (for optimistic concurrency)
    public var expectedLastMsgID: String?

    /// Expected last sequence number
    public var expectedLastSequence: UInt64?

    /// Expected last sequence number for the subject
    public var expectedLastSubjectSequence: UInt64?

    /// Timeout for the publish operation
    public var timeout: Duration?

    public init(
        messageID: String? = nil,
        expectedStream: String? = nil,
        expectedLastMsgID: String? = nil,
        expectedLastSequence: UInt64? = nil,
        expectedLastSubjectSequence: UInt64? = nil,
        timeout: Duration? = nil
    ) {
        self.messageID = messageID
        self.expectedStream = expectedStream
        self.expectedLastMsgID = expectedLastMsgID
        self.expectedLastSequence = expectedLastSequence
        self.expectedLastSubjectSequence = expectedLastSubjectSequence
        self.timeout = timeout
    }
}

/// Async publish acknowledgement for fire-and-forget with later confirmation
public actor PubAckFuture {
    private var result: Result<PubAck, Error>?
    private var continuation: CheckedContinuation<PubAck, Error>?

    /// Wait for the publish acknowledgement
    public func get() async throws -> PubAck {
        if let result = result {
            return try result.get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Resolve the future with a result
    func resolve(_ ack: PubAck) {
        result = .success(ack)
        continuation?.resume(returning: ack)
        continuation = nil
    }

    /// Reject the future with an error
    func reject(_ error: Error) {
        result = .failure(error)
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
