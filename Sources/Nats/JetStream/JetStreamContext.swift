// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import NIOCore

/// JetStream context for interacting with JetStream-enabled servers
public actor JetStreamContext {
    private let client: NatsClient
    private let prefix: String
    private let timeout: Duration

    /// JetStream API subjects
    private enum API {
        static func accountInfo(_ prefix: String) -> String { "\(prefix).INFO" }
        static func streamCreate(_ prefix: String) -> String { "\(prefix).STREAM.CREATE" }
        static func streamUpdate(_ prefix: String) -> String { "\(prefix).STREAM.UPDATE" }
        static func streamDelete(_ prefix: String, _ name: String) -> String { "\(prefix).STREAM.DELETE.\(name)" }
        static func streamInfo(_ prefix: String, _ name: String) -> String { "\(prefix).STREAM.INFO.\(name)" }
        static func streamList(_ prefix: String) -> String { "\(prefix).STREAM.LIST" }
        static func streamPurge(_ prefix: String, _ name: String) -> String { "\(prefix).STREAM.PURGE.\(name)" }
        static func streamMsg(_ prefix: String, _ name: String) -> String { "\(prefix).STREAM.MSG.GET.\(name)" }
        static func streamMsgDelete(_ prefix: String, _ name: String) -> String { "\(prefix).STREAM.MSG.DELETE.\(name)" }
        static func consumerCreate(_ prefix: String, _ stream: String) -> String { "\(prefix).CONSUMER.CREATE.\(stream)" }
        static func consumerCreateNamed(_ prefix: String, _ stream: String, _ consumer: String) -> String { "\(prefix).CONSUMER.CREATE.\(stream).\(consumer)" }
        static func consumerDelete(_ prefix: String, _ stream: String, _ consumer: String) -> String { "\(prefix).CONSUMER.DELETE.\(stream).\(consumer)" }
        static func consumerInfo(_ prefix: String, _ stream: String, _ consumer: String) -> String { "\(prefix).CONSUMER.INFO.\(stream).\(consumer)" }
        static func consumerList(_ prefix: String, _ stream: String) -> String { "\(prefix).CONSUMER.LIST.\(stream)" }
        static func consumerNext(_ prefix: String, _ stream: String, _ consumer: String) -> String { "\(prefix).CONSUMER.MSG.NEXT.\(stream).\(consumer)" }
    }

    /// Access to the underlying NATS client (internal use)
    var natsClient: NatsClient { client }

    /// Access to the JetStream API prefix
    var apiPrefix: String { prefix }

    init(client: NatsClient, prefix: String = "$JS.API", timeout: Duration = .seconds(5)) {
        self.client = client
        self.prefix = prefix
        self.timeout = timeout
    }

    // MARK: - Account Info

    /// Get JetStream account information
    public func accountInfo() async throws(JetStreamError) -> AccountInfo {
        let response = try await request(API.accountInfo(prefix), payload: ByteBuffer())
        return try decode(response, as: AccountInfo.self)
    }

    // MARK: - Stream Management

    /// Create a new stream
    public func createStream(_ config: StreamConfig) async throws(JetStreamError) -> Stream {
        guard !config.name.isEmpty else {
            throw .streamNameRequired
        }

        let payload = try encode(config)
        let response = try await request(API.streamCreate(prefix) + ".\(config.name)", payload: payload)
        let info = try decode(response, as: StreamInfo.self)

        return Stream(context: self, info: info)
    }

    /// Update an existing stream
    public func updateStream(_ config: StreamConfig) async throws(JetStreamError) -> Stream {
        guard !config.name.isEmpty else {
            throw .streamNameRequired
        }

        let payload = try encode(config)
        let response = try await request(API.streamUpdate(prefix) + ".\(config.name)", payload: payload)
        let info = try decode(response, as: StreamInfo.self)

        return Stream(context: self, info: info)
    }

    /// Delete a stream
    public func deleteStream(_ name: String) async throws(JetStreamError) {
        guard !name.isEmpty else {
            throw .streamNameRequired
        }

        _ = try await request(API.streamDelete(prefix, name), payload: ByteBuffer())
    }

    /// Get stream information
    public func stream(_ name: String) async throws(JetStreamError) -> Stream {
        guard !name.isEmpty else {
            throw .streamNameRequired
        }

        let response = try await request(API.streamInfo(prefix, name), payload: ByteBuffer())
        let info = try decode(response, as: StreamInfo.self)

        return Stream(context: self, info: info)
    }

    /// List all streams
    public func streams() -> AsyncThrowingStream<Stream, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var offset = 0
                    let limit = 256

                    while true {
                        let payload = try encode(["offset": offset])
                        let response = try await request(API.streamList(prefix), payload: payload)
                        let list = try decode(response, as: StreamListResponse.self)

                        for info in list.streams {
                            continuation.yield(Stream(context: self, info: info))
                        }

                        if list.streams.count < limit {
                            break
                        }
                        offset += list.streams.count
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Consumer Management

    /// Create a consumer for a stream
    public func createConsumer(
        stream: String,
        config: ConsumerConfig
    ) async throws(JetStreamError) -> Consumer {
        guard !stream.isEmpty else {
            throw .streamNameRequired
        }

        let request = CreateConsumerRequest(streamName: stream, config: config)
        let payload = try encode(request)

        let apiSubject: String
        if let name = config.name ?? config.durable {
            apiSubject = API.consumerCreateNamed(prefix, stream, name)
        } else {
            apiSubject = API.consumerCreate(prefix, stream)
        }

        let response = try await self.request(apiSubject, payload: payload)
        let info = try decode(response, as: ConsumerInfo.self)

        return Consumer(context: self, info: info, streamName: stream)
    }

    /// Delete a consumer
    public func deleteConsumer(stream: String, consumer: String) async throws(JetStreamError) {
        guard !stream.isEmpty else {
            throw .streamNameRequired
        }
        guard !consumer.isEmpty else {
            throw .consumerNameRequired
        }

        _ = try await request(API.consumerDelete(prefix, stream, consumer), payload: ByteBuffer())
    }

    /// Get consumer information
    public func consumer(stream: String, name: String) async throws(JetStreamError) -> Consumer {
        guard !stream.isEmpty else {
            throw .streamNameRequired
        }
        guard !name.isEmpty else {
            throw .consumerNameRequired
        }

        let response = try await request(API.consumerInfo(prefix, stream, name), payload: ByteBuffer())
        let info = try decode(response, as: ConsumerInfo.self)

        return Consumer(context: self, info: info, streamName: stream)
    }

    // MARK: - Publishing

    /// Publish a message to JetStream with acknowledgment
    public func publish(
        _ subject: String,
        payload: ByteBuffer,
        options: PublishOptions = PublishOptions()
    ) async throws(JetStreamError) -> PubAck {
        var headers = NatsHeaders()

        if let msgId = options.messageID {
            headers[NatsHeaders.Keys.msgId] = msgId
        }
        if let expectedStream = options.expectedStream {
            headers[NatsHeaders.Keys.expectedStream] = expectedStream
        }
        if let expectedLastMsgId = options.expectedLastMsgID {
            headers[NatsHeaders.Keys.expectedLastMsgId] = expectedLastMsgId
        }
        if let expectedLastSeq = options.expectedLastSequence {
            headers[NatsHeaders.Keys.expectedLastSequence] = String(expectedLastSeq)
        }
        if let expectedLastSubjectSeq = options.expectedLastSubjectSequence {
            headers[NatsHeaders.Keys.expectedLastSubjectSequence] = String(expectedLastSubjectSeq)
        }

        do {
            let response = try await client.request(
                subject, payload: payload,
                headers: headers.isEmpty ? nil : headers,
                timeout: timeout
            )

            return try Self.pubAck(from: response)
        } catch let error as JetStreamError {
            throw error
        } catch {
            throw JetStreamError.publishFailed(error.localizedDescription)
        }
    }

    /// Publish with custom headers and return PubAck (used internally by KV)
    func publishWithHeaders(
        _ subject: String,
        payload: ByteBuffer,
        headers: NatsHeaders
    ) async throws(JetStreamError) -> PubAck {
        do {
            let response = try await client.request(
                subject, payload: payload,
                headers: headers.isEmpty ? nil : headers,
                timeout: timeout
            )

            return try Self.pubAck(from: response)
        } catch let error as JetStreamError {
            throw error
        } catch {
            throw JetStreamError.publishFailed(error.localizedDescription)
        }
    }

    /// The ack for a JetStream publish, decoding the reply once.
    ///
    /// A publish reply is either an ack or an API error. The reply used to be
    /// decoded as an error first and then again as an ack — two JSON decodes
    /// per publish. `publish(_:payload:options:)` skipped the error decode and
    /// reported a rejected publish as an undecodable ack; both now report
    /// `apiError`.
    static func pubAck(from response: NatsMessage) throws -> PubAck {
        if let status = response.headers?.status, status >= 400 {
            let description = response.headers?.statusDescription ?? "Unknown error"
            throw JetStreamError.publishFailed(description)
        }

        let reply = try JSONDecoder().decode(PubAckReply.self, from: response.data)
        if let error = reply.error {
            throw JetStreamError.apiError(code: error.code, errorCode: error.errCode, description: error.description)
        }
        guard let stream = reply.stream, let seq = reply.seq else {
            throw JetStreamError.publishFailed("Publish reply carried neither an ack nor an error")
        }
        return PubAck(stream: stream, seq: seq, duplicate: reply.duplicate, domain: reply.domain)
    }

    // MARK: - Internal Methods

    func request(_ subject: String, payload: ByteBuffer?, headers: NatsHeaders?) async throws(JetStreamError) -> NatsMessage {
        do {
            let response = try await client.request(
                subject, payload: payload ?? ByteBuffer(),
                headers: headers,
                timeout: timeout
            )

            // Check for JetStream error response
            if let errorResponse = try? JSONDecoder().decode(JSErrorResponse.self, from: response.data),
               errorResponse.error != nil {
                throw JetStreamError.apiError(
                    code: errorResponse.error!.code,
                    errorCode: errorResponse.error!.errCode,
                    description: errorResponse.error!.description
                )
            }

            // Defensive only: `NatsClient.handleMessage` intercepts the 503 and
            // resumes the request by throwing `ProtocolError.noResponders`, so a
            // no-responders reply does not reach this point today. `mapping`
            // handles the live path. Kept so the check still holds if the client
            // ever delivers the 503 as a normal message.
            if let headers = response.headers, headers.isNoResponders {
                throw JetStreamError.notEnabled
            }

            return response
        } catch {
            throw JetStreamError.mapping(error, operation: "request", timeout: timeout)
        }
    }

    /// Raw request that returns the NatsMessage without checking for JSON error body.
    /// Used for Direct Get which returns data in headers + body, not JSON.
    func rawRequest(_ subject: String, payload: ByteBuffer?, headers: NatsHeaders? = nil) async throws(JetStreamError) -> NatsMessage {
        do {
            let response = try await client.request(
                subject, payload: payload ?? ByteBuffer(),
                headers: headers,
                timeout: timeout
            )

            // Check for no responders
            if let hdrs = response.headers, hdrs.isNoResponders {
                throw JetStreamError.notEnabled
            }

            return response
        } catch {
            throw JetStreamError.mapping(error, operation: "rawRequest", timeout: timeout)
        }
    }

    func request(_ subject: String, payload: ByteBuffer?) async throws(JetStreamError) -> NatsMessage {
        do {
            let response = try await client.request(subject, payload: payload ?? ByteBuffer(), timeout: timeout)

            // Check for JetStream error response
            if let errorResponse = try? JSONDecoder().decode(JSErrorResponse.self, from: response.data),
               errorResponse.error != nil {
                throw JetStreamError.apiError(
                    code: errorResponse.error!.code,
                    errorCode: errorResponse.error!.errCode,
                    description: errorResponse.error!.description
                )
            }

            // Defensive only: `NatsClient.handleMessage` intercepts the 503 and
            // resumes the request by throwing `ProtocolError.noResponders`, so a
            // no-responders reply does not reach this point today. `mapping`
            // handles the live path. Kept so the check still holds if the client
            // ever delivers the 503 as a normal message.
            if let headers = response.headers, headers.isNoResponders {
                throw JetStreamError.notEnabled
            }

            return response
        } catch {
            throw JetStreamError.mapping(error, operation: "request", timeout: timeout)
        }
    }

    /// Subject a pull request for `consumer` is published to.
    nonisolated func consumerNextSubject(stream: String, consumer: String) -> String {
        API.consumerNext(prefix, stream, consumer)
    }

    /// Default deadline for API requests, and for a fetch without `maxWait`.
    nonisolated var requestTimeout: Duration { timeout }

    /// The sequence of the first message stored at or after `date`, or the
    /// stream's last sequence + 1 when every message is older.
    ///
    /// Asks MSG.GET with `start_time` (nats-server 2.11+). A server that does
    /// not know the field rejects the request, and the answer then comes from a
    /// consumer created with `by_start_time`, whose delivered stream sequence
    /// starts one below the first match; it is deleted straight away and never
    /// pulls. That fallback cannot be created on a work-queue stream that
    /// already has an unfiltered consumer, and throws there.
    func sequence(stream: String, atOrAfter date: Date) async throws(JetStreamError) -> UInt64 {
        // Read before the lookup: anything stored after this is newer than the
        // cutoff, so "every message is older" can safely mean "below here".
        let streamInfo = try decode(try await request(API.streamInfo(prefix, stream), payload: ByteBuffer()), as: StreamInfo.self)

        do {
            let response = try await request(
                API.streamMsg(prefix, stream),
                payload: encode(StartTimeMessageRequest(startTime: date))
            )
            return try decode(response, as: StartTimeMessageResponse.self).message.seq
        } catch {
            if case .apiError(let code, let errorCode, _) = error, code == 404 || errorCode == 10037 {
                return streamInfo.state.lastSeq + 1
            }
            guard case .apiError = error else { throw error }
            // Otherwise a server without `start_time`: resolve through a consumer.
        }

        let consumer = try await createConsumer(
            stream: stream,
            config: ConsumerConfig(
                deliverPolicy: .byStartTime,
                optStartTime: date,
                // Explicit so that work-queue streams accept it; it never pulls.
                ackPolicy: .explicit,
                inactiveThreshold: .seconds(30),
                memStorage: true
            )
        )
        let info = await consumer.info
        try? await deleteConsumer(stream: stream, consumer: info.name)
        return info.delivered.streamSeq + 1
    }

    // MARK: - Encoding/Decoding Helpers

    /// Encoder for JetStream API payloads.
    ///
    /// Dates go out as RFC 3339 with fractional seconds, the only form the
    /// server accepts. Foundation's default encodes a `Date` as seconds since
    /// 2001, which the server rejects — so every `optStartTime` was unusable.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    nonisolated func encode<T: Encodable>(_ value: T) throws(JetStreamError) -> ByteBuffer {
        do {
            let data = try Self.makeEncoder().encode(value)
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            return buffer
        } catch {
            throw JetStreamError.invalidStreamConfig(error.localizedDescription)
        }
    }

    func decode<T: Decodable>(_ message: NatsMessage, as type: T.Type) throws(JetStreamError) -> T {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateString = try container.decode(String.self)

                if let date = RFC3339.date(from: dateString) {
                    return date
                }

                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateString)")
            }
            return try decoder.decode(type, from: message.data)
        } catch {
            throw JetStreamError.invalidAck(error.localizedDescription)
        }
    }
}

// MARK: - Supporting Types

/// A publish reply: an ack, or an API error.
struct PubAckReply: Decodable {
    let error: JSErrorResponse.JSError?
    let stream: String?
    let seq: UInt64?
    let duplicate: Bool?
    let domain: String?
}

/// MSG.GET by time. Only `seq` is read back.
struct StartTimeMessageRequest: Encodable {
    let startTime: Date

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
    }
}

struct StartTimeMessageResponse: Decodable {
    struct Message: Decodable {
        let seq: UInt64
    }
    let message: Message
}

struct JSErrorResponse: Codable {
    let error: JSError?

    struct JSError: Codable {
        let code: Int
        let errCode: Int
        let description: String

        enum CodingKeys: String, CodingKey {
            case code
            case errCode = "err_code"
            case description
        }
    }
}

struct StreamListResponse: Codable {
    let total: Int
    let offset: Int
    let limit: Int
    let streams: [StreamInfo]
}

struct CreateConsumerRequest: Codable {
    let streamName: String
    let config: ConsumerConfig

    enum CodingKeys: String, CodingKey {
        case streamName = "stream_name"
        case config
    }
}

struct NextMessageRequest: Codable {
    let batch: Int
    let maxBytes: Int?
    let expires: Int64?
    let noWait: Bool?
    let idleHeartbeat: Int64?

    init(batch: Int = 1, maxBytes: Int? = nil, expires: Int64? = nil, noWait: Bool? = nil, idleHeartbeat: Int64? = nil) {
        self.batch = batch
        self.maxBytes = maxBytes
        self.expires = expires
        self.noWait = noWait
        self.idleHeartbeat = idleHeartbeat
    }

    enum CodingKeys: String, CodingKey {
        case batch
        case maxBytes = "max_bytes"
        case expires
        case noWait = "no_wait"
        case idleHeartbeat = "idle_heartbeat"
    }
}

// MARK: - NatsClient Extension

extension NatsClient {
    /// Get JetStream context
    public func jetStream(
        prefix: String = "$JS.API",
        timeout: Duration = .seconds(5)
    ) async throws(JetStreamError) -> JetStreamContext {
        // `.notConnected`, NOT `.notEnabled`. This guard fires whenever the
        // client is not in `.connected` — including every reconnect window —
        // and reporting that as "JetStream is not enabled" invites callers to
        // cache a permanent verdict from a transient blip.
        guard state.canAcceptOperations else {
            throw .notConnected
        }

        return JetStreamContext(client: self, prefix: prefix, timeout: timeout)
    }
}
