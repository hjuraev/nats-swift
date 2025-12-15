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
            let response = try await client.request(subject, payload: payload, timeout: timeout)

            // Check for error in response
            if let status = response.headers?.status, status >= 400 {
                let description = response.headers?.statusDescription ?? "Unknown error"
                throw JetStreamError.publishFailed(description)
            }

            return try JSONDecoder().decode(PubAck.self, from: response.data)
        } catch let error as JetStreamError {
            throw error
        } catch {
            throw JetStreamError.publishFailed(error.localizedDescription)
        }
    }

    // MARK: - Internal Methods

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

            // Check for no responders
            if let headers = response.headers, headers.isNoResponders {
                throw JetStreamError.notEnabled
            }

            return response
        } catch let error as JetStreamError {
            throw error
        } catch {
            throw JetStreamError.timeout(operation: "request", after: timeout)
        }
    }

    func getNextMessage(
        stream: String,
        consumer: String,
        batch: Int,
        expires: Duration?
    ) async throws(JetStreamError) -> [JetStreamMessage] {
        let effectiveExpires = expires ?? timeout
        let expiresNanos = Int64(effectiveExpires.components.seconds * 1_000_000_000) +
                          Int64(effectiveExpires.components.attoseconds / 1_000_000_000)

        let request = NextMessageRequest(
            batch: batch,
            expires: expiresNanos
        )

        let payload = try encode(request)
        let subject = API.consumerNext(prefix, stream, consumer)

        // Create a unique inbox for receiving messages
        let inbox = "_INBOX.\(UUID().uuidString)"

        do {
            // Subscribe to the inbox to receive messages
            let subscription = try await client.subscribe(inbox)

            // Send the pull request with our inbox as reply-to
            try await client.publish(subject, payload: payload, reply: inbox)

            var messages: [JetStreamMessage] = []
            let deadline = ContinuousClock.now + effectiveExpires

            // Collect messages until batch is filled, timeout, or terminal status
            for await msg in subscription {
                // Check for status headers (404 No Messages, 408 Timeout, 409 Exceeded MaxRequestBatch)
                if let headers = msg.headers {
                    if headers.isNoMessages || headers.isTimeout {
                        // No more messages available
                        break
                    }
                    if let status = headers.status, status >= 400 {
                        // Some other error status
                        break
                    }
                }

                // Parse as JetStream message
                do {
                    let jsMessage = try JetStreamMessage.parse(msg, context: self, stream: stream, consumer: consumer)
                    messages.append(jsMessage)
                } catch {
                    // Skip messages that can't be parsed (might be status messages)
                    continue
                }

                // Check if we've collected enough messages
                if messages.count >= batch {
                    break
                }

                // Check timeout
                if ContinuousClock.now >= deadline {
                    break
                }
            }

            await subscription.unsubscribe()
            return messages
        } catch {
            throw JetStreamError.pullFailed(error.localizedDescription)
        }
    }

    // MARK: - Encoding/Decoding Helpers

    private func encode<T: Encodable>(_ value: T) throws(JetStreamError) -> ByteBuffer {
        do {
            let data = try JSONEncoder().encode(value)
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            return buffer
        } catch {
            throw JetStreamError.invalidStreamConfig(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ message: NatsMessage, as type: T.Type) throws(JetStreamError) -> T {
        do {
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
            return try decoder.decode(type, from: message.data)
        } catch {
            throw JetStreamError.invalidAck(error.localizedDescription)
        }
    }
}

// MARK: - Supporting Types

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
    let expires: Int64?
    let noWait: Bool?
    let idleHeartbeat: Int64?

    init(batch: Int = 1, expires: Int64? = nil, noWait: Bool? = nil, idleHeartbeat: Int64? = nil) {
        self.batch = batch
        self.expires = expires
        self.noWait = noWait
        self.idleHeartbeat = idleHeartbeat
    }

    enum CodingKeys: String, CodingKey {
        case batch
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
        guard state.canAcceptOperations else {
            throw .notEnabled
        }

        return JetStreamContext(client: self, prefix: prefix, timeout: timeout)
    }
}
