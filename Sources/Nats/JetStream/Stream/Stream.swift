// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import NIOCore

/// A JetStream stream handle
public actor Stream {
    private let context: JetStreamContext
    private var _info: StreamInfo

    /// Current stream information
    public var info: StreamInfo { _info }

    /// Stream name
    public var name: String { _info.config.name }

    init(context: JetStreamContext, info: StreamInfo) {
        self.context = context
        self._info = info
    }

    // MARK: - Operations

    /// Refresh stream information from server
    public func refresh() async throws(JetStreamError) {
        let stream = try await context.stream(name)
        self._info = await stream.info
    }

    /// Delete this stream
    public func delete() async throws(JetStreamError) {
        try await context.deleteStream(name)
    }

    /// Purge all messages from the stream
    public func purge() async throws(JetStreamError) -> PurgeResponse {
        try await purge(request: PurgeRequest())
    }

    /// Purge messages matching a filter
    public func purge(subject: String) async throws(JetStreamError) -> PurgeResponse {
        try await purge(request: PurgeRequest(filter: subject))
    }

    /// Purge messages with a sequence below `seq`.
    public func purge(upToSequence seq: UInt64) async throws(JetStreamError) -> PurgeResponse {
        guard seq > 1 else { return Self.nothingPurged }
        return try await purge(request: PurgeRequest(seq: seq))
    }

    /// Purge messages matching a subject filter, optionally keeping some
    public func purge(subject: String, keep: UInt64) async throws(JetStreamError) -> PurgeResponse {
        try await purge(request: PurgeRequest(filter: subject, keep: keep))
    }

    /// Purge messages on `subject` with a sequence below `seq`, keeping `seq`
    /// and everything after it.
    ///
    /// The sequence bound is what makes a subject purge safe against a
    /// concurrent write: a message stored after the caller chose `seq` has a
    /// higher sequence and survives, where `purge(subject:)` would remove it.
    public func purge(subject: String, upToSequence seq: UInt64) async throws(JetStreamError) -> PurgeResponse {
        guard seq > 1 else { return Self.nothingPurged }
        return try await purge(request: PurgeRequest(filter: subject, seq: seq))
    }

    /// Nothing lies below sequence 1, so a bound of 0 or 1 purges nothing —
    /// and must not reach the server: file storage reads `seq: 1` as no bound
    /// at all and purges everything (on `filter`, everything on that subject),
    /// while memory storage purges nothing. Measured on nats-server 2.12.
    private static let nothingPurged = PurgeResponse(success: true, purged: 0)

    /// Purge messages stored more than `threshold` ago, keeping newer ones.
    ///
    /// The purge API has no time filter, so the cutoff is resolved to the
    /// sequence of the first message stored at or after it, and everything
    /// below that sequence is purged. Messages published while this runs have
    /// higher sequences and are kept.
    ///
    /// The cutoff is `now - threshold` on this client's clock: a clock running
    /// ahead of the server's purges messages newer than intended, so keep
    /// `threshold` well above any skew.
    ///
    /// This used to send `keep: 0` with no filter, which the server reads as
    /// "purge everything": every call emptied the stream regardless of age.
    public func purge(olderThan threshold: Duration) async throws(JetStreamError) -> PurgeResponse {
        let cutoff = Date().addingTimeInterval(-threshold.timeInterval)
        let firstKept = try await context.sequence(stream: name, atOrAfter: cutoff)
        return try await purge(upToSequence: firstKept)
    }

    private func purge(request: PurgeRequest) async throws(JetStreamError) -> PurgeResponse {
        var payload = ByteBuffer()
        do {
            let data = try JSONEncoder().encode(request)
            payload.writeBytes(data)
        } catch {
            throw JetStreamError.invalidStreamConfig(error.localizedDescription)
        }
        let prefix = await context.apiPrefix
        let response = try await context.request("\(prefix).STREAM.PURGE.\(name)", payload: payload)
        do {
            return try JSONDecoder().decode(PurgeResponse.self, from: response.data)
        } catch {
            throw JetStreamError.invalidAck(error.localizedDescription)
        }
    }

    /// Get a message by sequence number
    public func getMessage(seq: UInt64) async throws(JetStreamError) -> StoredMessage {
        let request = GetMessageRequest(seq: seq)
        var payload = ByteBuffer()
        do {
            let data = try JSONEncoder().encode(request)
            payload.writeBytes(data)
        } catch {
            throw JetStreamError.invalidStreamConfig(error.localizedDescription)
        }
        let response = try await context.request("$JS.API.STREAM.MSG.GET.\(name)", payload: payload)
        do {
            let decoder = Self.makeDecoder()
            let wrapper = try decoder.decode(StoredMessageResponse.self, from: response.data)
            return wrapper.message
        } catch {
            throw JetStreamError.invalidAck(error.localizedDescription)
        }
    }

    /// Get the last message for a subject
    public func getLastMessage(subject: String) async throws(JetStreamError) -> StoredMessage {
        let request = GetMessageRequest(lastBySubject: subject)
        var payload = ByteBuffer()
        do {
            let data = try JSONEncoder().encode(request)
            payload.writeBytes(data)
        } catch {
            throw JetStreamError.invalidStreamConfig(error.localizedDescription)
        }
        let response = try await context.request("$JS.API.STREAM.MSG.GET.\(name)", payload: payload)
        do {
            let decoder = Self.makeDecoder()
            let wrapper = try decoder.decode(StoredMessageResponse.self, from: response.data)
            return wrapper.message
        } catch {
            throw JetStreamError.invalidAck(error.localizedDescription)
        }
    }

    /// Delete a message by sequence number
    public func deleteMessage(seq: UInt64) async throws(JetStreamError) {
        let request = DeleteMessageRequest(seq: seq)
        var payload = ByteBuffer()
        do {
            let data = try JSONEncoder().encode(request)
            payload.writeBytes(data)
        } catch {
            throw JetStreamError.invalidStreamConfig(error.localizedDescription)
        }
        _ = try await context.request("$JS.API.STREAM.MSG.DELETE.\(name)", payload: payload)
    }

    // MARK: - Consumer Management

    /// Create a consumer for this stream
    public func createConsumer(config: ConsumerConfig) async throws(JetStreamError) -> Consumer {
        try await context.createConsumer(stream: name, config: config)
    }

    /// Get a consumer by name
    public func consumer(_ name: String) async throws(JetStreamError) -> Consumer {
        try await context.consumer(stream: self.name, name: name)
    }

    /// Delete a consumer
    public func deleteConsumer(_ name: String) async throws(JetStreamError) {
        try await context.deleteConsumer(stream: self.name, consumer: name)
    }

    // MARK: - Helpers

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // Try ISO8601 with fractional seconds
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                return date
            }

            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateString)")
        }
        return decoder
    }
}

// MARK: - Supporting Types

/// Request to purge messages
struct PurgeRequest: Codable {
    let filter: String?
    let seq: UInt64?
    let keep: UInt64?

    init(filter: String? = nil, seq: UInt64? = nil, keep: UInt64? = nil) {
        self.filter = filter
        self.seq = seq
        self.keep = keep
    }
}

/// Response from purge operation
public struct PurgeResponse: Codable, Sendable {
    /// Whether the operation was successful
    public let success: Bool

    /// Number of messages purged
    public let purged: UInt64
}

/// Request to get a message
struct GetMessageRequest: Codable {
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

/// Response wrapper for stored message
struct StoredMessageResponse: Codable {
    let message: StoredMessage
}

/// A message stored in a stream
public struct StoredMessage: Codable, Sendable {
    /// Subject the message was published to
    public let subject: String

    /// Sequence number in the stream
    public let seq: UInt64

    /// Message headers (base64 encoded)
    public let hdrs: String?

    /// Message data (base64 encoded)
    public let data: String?

    /// When the message was stored
    public let time: Date
}

/// Request to delete a message
struct DeleteMessageRequest: Codable {
    let seq: UInt64
    let noErase: Bool?

    init(seq: UInt64, noErase: Bool? = nil) {
        self.seq = seq
        self.noErase = noErase
    }

    enum CodingKeys: String, CodingKey {
        case seq
        case noErase = "no_erase"
    }
}
