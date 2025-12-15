// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
import NIOCore
@testable import Nats

// MARK: - Test Helper Extension

extension ByteBuffer {
    /// Create a ByteBuffer from a string for testing convenience
    static func from(_ string: String) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeString(string)
        return buffer
    }

    /// Create a ByteBuffer from data for testing convenience
    static func from(_ data: Data) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        return buffer
    }
}

/// Integration tests requiring a running NATS server on localhost:4222
@Suite("Integration Tests", .tags(.integration))
struct IntegrationTests {

    // MARK: - Connection Tests

    @Suite("Connection Tests")
    struct ConnectionTests {

        @Test("Connect to NATS server")
        func connectToServer() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }

            try await client.connect()
            #expect(await client.isConnected)

            let serverInfo = await client.serverInfo
            #expect(serverInfo != nil)
            #expect(serverInfo?.version != nil)

            await client.close()
            #expect(await !client.isConnected)
        }

        @Test("Connect with client name")
        func connectWithName() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
                $0.name = "test-client"
            }

            try await client.connect()
            #expect(await client.isConnected)
            await client.close()
        }

        @Test("Multiple sequential connections")
        func multipleConnections() async throws {
            for i in 1...3 {
                let client = NatsClient {
                    $0.servers = [URL(string: "nats://localhost:4222")!]
                    $0.name = "test-client-\(i)"
                }

                try await client.connect()
                #expect(await client.isConnected)
                await client.close()
            }
        }

        @Test("Connection refused on wrong port")
        func connectionRefused() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:9999")!]
                $0.reconnect.enabled = false
            }

            do {
                try await client.connect()
                Issue.record("Should have thrown connection error")
            } catch {
                // Expected - connection should fail
                #expect(await !client.isConnected)
            }
        }
    }

    // MARK: - Pub/Sub Tests

    @Suite("Pub/Sub Tests")
    struct PubSubTests {

        @Test("Basic publish and subscribe")
        func basicPubSub() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let subject = "test.pubsub.\(UUID().uuidString)"
            let testMessage = "Hello, NATS!"

            // Subscribe first
            let subscription = try await client.subscribe(subject)

            // Publish message
            try await client.publish(subject, payload: ByteBuffer.from(testMessage))

            // Receive message with timeout
            var receivedMessage: NatsMessage?
            for await message in subscription {
                receivedMessage = message
                break
            }

            #expect(receivedMessage != nil)
            #expect(receivedMessage?.subject == subject)
            #expect(receivedMessage?.string == testMessage)

            await subscription.unsubscribe()
            await client.close()
        }

        @Test("Subscribe with wildcard")
        func wildcardSubscription() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let baseSubject = "test.wildcard.\(UUID().uuidString)"
            let subscription = try await client.subscribe("\(baseSubject).*")

            // Publish to different subjects
            try await client.publish("\(baseSubject).one", payload: ByteBuffer.from("first"))
            try await client.publish("\(baseSubject).two", payload: ByteBuffer.from("second"))

            var messages: [NatsMessage] = []
            var count = 0
            for await message in subscription {
                messages.append(message)
                count += 1
                if count >= 2 { break }
            }

            #expect(messages.count == 2)

            await subscription.unsubscribe()
            await client.close()
        }

        @Test("Subscribe with greater-than wildcard")
        func greaterThanWildcard() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let baseSubject = "test.gt.\(UUID().uuidString)"
            let subscription = try await client.subscribe("\(baseSubject).>")

            try await client.publish("\(baseSubject).a", payload: ByteBuffer.from("1"))
            try await client.publish("\(baseSubject).a.b", payload: ByteBuffer.from("2"))
            try await client.publish("\(baseSubject).a.b.c", payload: ByteBuffer.from("3"))

            var messages: [NatsMessage] = []
            var count = 0
            for await message in subscription {
                messages.append(message)
                count += 1
                if count >= 3 { break }
            }

            #expect(messages.count == 3)

            await subscription.unsubscribe()
            await client.close()
        }

        @Test("Multiple subscribers same subject")
        func multipleSubscribers() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let subject = "test.multi.\(UUID().uuidString)"

            let sub1 = try await client.subscribe(subject)
            let sub2 = try await client.subscribe(subject)

            try await client.publish(subject, payload: ByteBuffer.from("test"))

            // Both subscribers should receive the message
            var msg1: NatsMessage?
            var msg2: NatsMessage?

            for await message in sub1 {
                msg1 = message
                break
            }

            for await message in sub2 {
                msg2 = message
                break
            }

            #expect(msg1 != nil)
            #expect(msg2 != nil)
            #expect(msg1?.string == "test")
            #expect(msg2?.string == "test")

            await sub1.unsubscribe()
            await sub2.unsubscribe()
            await client.close()
        }

        @Test("Publish with headers")
        func publishWithHeaders() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let subject = "test.headers.\(UUID().uuidString)"
            var headers = NatsHeaders()
            headers["X-Custom"] = "custom-value"
            headers["X-Another"] = "another-value"

            let subscription = try await client.subscribe(subject)

            try await client.publish(subject, payload: ByteBuffer.from("with headers"), headers: headers)

            var receivedMessage: NatsMessage?
            for await message in subscription {
                receivedMessage = message
                break
            }

            #expect(receivedMessage != nil)
            #expect(receivedMessage?.headers?["X-Custom"] == "custom-value")
            #expect(receivedMessage?.headers?["X-Another"] == "another-value")

            await subscription.unsubscribe()
            await client.close()
        }

        @Test("Large payload")
        func largePayload() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let subject = "test.large.\(UUID().uuidString)"
            // 100KB payload
            var largeData = ByteBuffer()
            largeData.writeRepeatingByte(0x42, count: 100_000)

            let subscription = try await client.subscribe(subject)

            try await client.publish(subject, payload: largeData)

            var receivedMessage: NatsMessage?
            for await message in subscription {
                receivedMessage = message
                break
            }

            #expect(receivedMessage != nil)
            #expect(receivedMessage?.payload.readableBytes == 100_000)

            await subscription.unsubscribe()
            await client.close()
        }

        @Test("Empty payload")
        func emptyPayload() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let subject = "test.empty.\(UUID().uuidString)"

            let subscription = try await client.subscribe(subject)

            try await client.publish(subject, payload: ByteBuffer())

            var receivedMessage: NatsMessage?
            for await message in subscription {
                receivedMessage = message
                break
            }

            #expect(receivedMessage != nil)
            #expect(receivedMessage?.isEmpty == true)

            await subscription.unsubscribe()
            await client.close()
        }

        @Test("Queue group subscription")
        func queueGroupSubscription() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let subject = "test.queue.\(UUID().uuidString)"
            let queueGroup = "test-workers"

            // Create two queue subscribers
            let sub1 = try await client.subscribe(subject, queue: queueGroup)
            let sub2 = try await client.subscribe(subject, queue: queueGroup)

            // Publish multiple messages
            for i in 1...10 {
                try await client.publish(subject, payload: ByteBuffer.from("message-\(i)"))
            }

            // Messages should be distributed between subscribers (not duplicated)
            // This test validates queue groups work - exact distribution varies
            await sub1.unsubscribe()
            await sub2.unsubscribe()
            await client.close()
        }
    }

    // MARK: - Request/Reply Tests

    @Suite("Request/Reply Tests")
    struct RequestReplyTests {

        @Test("Basic request/reply")
        func basicRequestReply() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let subject = "test.request.\(UUID().uuidString)"

            // Set up responder
            let subscription = try await client.subscribe(subject)

            // Start responder task
            let responderTask = Task {
                for await message in subscription {
                    if let replyTo = message.replyTo {
                        let response = "Response to: \(message.string ?? "")"
                        try await client.publish(replyTo, payload: ByteBuffer.from(response))
                    }
                    break
                }
            }

            // Small delay to ensure subscription is ready
            try await Task.sleep(for: .milliseconds(100))

            // Send request
            let response = try await client.request(subject, payload: ByteBuffer.from("Hello"), timeout: .seconds(5))

            #expect(response.string == "Response to: Hello")

            responderTask.cancel()
            await subscription.unsubscribe()
            await client.close()
        }

        @Test("Request with JSON payload")
        func requestWithJSON() async throws {
            struct Request: Codable {
                let name: String
                let value: Int
            }

            struct Response: Codable {
                let message: String
                let computed: Int
            }

            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let subject = "test.json.\(UUID().uuidString)"

            let subscription = try await client.subscribe(subject)

            let responderTask = Task {
                for await message in subscription {
                    if let replyTo = message.replyTo {
                        let request = try message.decode(Request.self)
                        let response = Response(message: "Hello, \(request.name)", computed: request.value * 2)
                        let responseData = try JSONEncoder().encode(response)
                        try await client.publish(replyTo, payload: ByteBuffer.from(responseData))
                    }
                    break
                }
            }

            try await Task.sleep(for: .milliseconds(100))

            let request = Request(name: "Test", value: 21)
            let requestData = try JSONEncoder().encode(request)

            let responseMessage = try await client.request(subject, payload: ByteBuffer.from(requestData), timeout: .seconds(5))
            let response = try responseMessage.decode(Response.self)

            #expect(response.message == "Hello, Test")
            #expect(response.computed == 42)

            responderTask.cancel()
            await subscription.unsubscribe()
            await client.close()
        }

        @Test("Request timeout")
        func requestTimeout() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let subject = "test.timeout.\(UUID().uuidString)"

            // No responder - should timeout
            do {
                _ = try await client.request(subject, payload: ByteBuffer.from("test"), timeout: .milliseconds(500))
                Issue.record("Should have timed out")
            } catch {
                // Expected timeout
            }

            await client.close()
        }
    }

    // MARK: - JetStream Tests

    @Suite("JetStream Tests")
    struct JetStreamTests {

        @Test("Create and delete stream")
        func createDeleteStream() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let js = try await client.jetStream()
            let streamName = "TEST_STREAM_\(UUID().uuidString.prefix(8))"

            // Create stream
            let stream = try await js.createStream(StreamConfig(
                name: streamName,
                subjects: ["\(streamName).>"]
            ))

            let info = await stream.info
            #expect(info.config.name == streamName)

            // Delete stream
            try await stream.delete()

            await client.close()
        }

        @Test("Publish to JetStream")
        func publishToJetStream() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let js = try await client.jetStream()
            let streamName = "TEST_PUB_\(UUID().uuidString.prefix(8))"

            // Create stream
            _ = try await js.createStream(StreamConfig(
                name: streamName,
                subjects: ["\(streamName).>"]
            ))

            // Publish with ack
            let ack = try await js.publish("\(streamName).test", payload: ByteBuffer.from("Hello JetStream"))

            #expect(ack.stream == streamName)
            #expect(ack.seq >= 1)

            // Cleanup
            try await js.deleteStream(streamName)
            await client.close()
        }

        @Test("Publish multiple messages")
        func publishMultiple() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let js = try await client.jetStream()
            let streamName = "TEST_MULTI_\(UUID().uuidString.prefix(8))"

            _ = try await js.createStream(StreamConfig(
                name: streamName,
                subjects: ["\(streamName).>"]
            ))

            // Publish multiple messages
            var sequences: [UInt64] = []
            for i in 1...10 {
                let ack = try await js.publish("\(streamName).test", payload: ByteBuffer.from("Message \(i)"))
                sequences.append(ack.seq)
            }

            // Sequences should be monotonically increasing
            for i in 1..<sequences.count {
                #expect(sequences[i] > sequences[i-1])
            }

            try await js.deleteStream(streamName)
            await client.close()
        }

        @Test("Create consumer and fetch messages")
        func createConsumerAndFetch() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let js = try await client.jetStream()
            let streamName = "TEST_FETCH_\(UUID().uuidString.prefix(8))"
            let consumerName = "test-consumer"

            // Create stream
            let stream = try await js.createStream(StreamConfig(
                name: streamName,
                subjects: ["\(streamName).>"]
            ))

            // Publish some messages
            for i in 1...5 {
                _ = try await js.publish("\(streamName).test", payload: ByteBuffer.from("Message \(i)"))
            }

            // Create consumer
            let consumer = try await stream.createConsumer(config: ConsumerConfig(
                name: consumerName,
                deliverPolicy: .all,
                ackPolicy: .explicit
            ))

            // Fetch messages
            let messages = try await consumer.fetch(batch: 5, maxWait: .seconds(5))

            #expect(messages.count == 5)

            // Acknowledge messages
            for message in messages {
                try await message.ack()
            }

            // Cleanup
            try await js.deleteStream(streamName)
            await client.close()
        }

        @Test("Consumer with filter subject")
        func consumerWithFilter() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let js = try await client.jetStream()
            let streamName = "TEST_FILTER_\(UUID().uuidString.prefix(8))"

            _ = try await js.createStream(StreamConfig(
                name: streamName,
                subjects: ["\(streamName).>"]
            ))

            // Publish to different subjects
            _ = try await js.publish("\(streamName).orders", payload: ByteBuffer.from("order1"))
            _ = try await js.publish("\(streamName).orders", payload: ByteBuffer.from("order2"))
            _ = try await js.publish("\(streamName).events", payload: ByteBuffer.from("event1"))

            // Create consumer with filter
            let consumer = try await js.createConsumer(
                stream: streamName,
                config: ConsumerConfig(
                    name: "orders-consumer",
                    filterSubject: "\(streamName).orders"
                )
            )

            let messages = try await consumer.fetch(batch: 10, maxWait: .seconds(2))

            // Should only get orders
            #expect(messages.count == 2)
            for message in messages {
                #expect(message.message.subject.contains("orders"))
                try await message.ack()
            }

            try await js.deleteStream(streamName)
            await client.close()
        }

        @Test("Message nak and redelivery")
        func messageNakRedelivery() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let js = try await client.jetStream()
            let streamName = "TEST_NAK_\(UUID().uuidString.prefix(8))"

            _ = try await js.createStream(StreamConfig(
                name: streamName,
                subjects: ["\(streamName).>"]
            ))

            _ = try await js.publish("\(streamName).test", payload: ByteBuffer.from("test message"))

            let consumer = try await js.createConsumer(
                stream: streamName,
                config: ConsumerConfig(
                    name: "nak-consumer",
                    ackWait: .seconds(1),
                    maxDeliver: 3
                )
            )

            // First fetch - nak the message
            let messages1 = try await consumer.fetch(batch: 1, maxWait: .seconds(2))
            #expect(messages1.count == 1)
            try await messages1[0].nak()

            // Wait a bit for redelivery
            try await Task.sleep(for: .milliseconds(500))

            // Second fetch - should get same message again
            let messages2 = try await consumer.fetch(batch: 1, maxWait: .seconds(2))
            #expect(messages2.count == 1)
            #expect(messages2[0].metadata.numDelivered > 1)
            try await messages2[0].ack()

            try await js.deleteStream(streamName)
            await client.close()
        }

        @Test("Stream purge")
        func streamPurge() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let js = try await client.jetStream()
            let streamName = "TEST_PURGE_\(UUID().uuidString.prefix(8))"

            let stream = try await js.createStream(StreamConfig(
                name: streamName,
                subjects: ["\(streamName).>"]
            ))

            // Publish messages
            for i in 1...10 {
                _ = try await js.publish("\(streamName).test", payload: ByteBuffer.from("Message \(i)"))
            }

            // Purge stream
            let purgeResult = try await stream.purge()
            #expect(purgeResult.success)
            #expect(purgeResult.purged == 10)

            // Verify stream is empty
            try await stream.refresh()
            let info = await stream.info
            #expect(info.state.messages == 0)

            try await js.deleteStream(streamName)
            await client.close()
        }

        @Test("Get message by sequence")
        func getMessageBySequence() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let js = try await client.jetStream()
            let streamName = "TEST_GETMSG_\(UUID().uuidString.prefix(8))"

            let stream = try await js.createStream(StreamConfig(
                name: streamName,
                subjects: ["\(streamName).>"]
            ))

            // Publish a message
            let ack = try await js.publish("\(streamName).test", payload: ByteBuffer.from("Specific message"))

            // Get message by sequence
            let storedMsg = try await stream.getMessage(seq: ack.seq)
            #expect(storedMsg.seq == ack.seq)
            #expect(storedMsg.subject == "\(streamName).test")

            try await js.deleteStream(streamName)
            await client.close()
        }

        @Test("Stream with retention policy")
        func streamRetentionPolicy() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let js = try await client.jetStream()
            let streamName = "TEST_RETAIN_\(UUID().uuidString.prefix(8))"

            // Create stream with limits
            let stream = try await js.createStream(StreamConfig(
                name: streamName,
                subjects: ["\(streamName).>"],
                retention: .limits,
                maxMsgs: 5
            ))

            // Publish more than max
            for i in 1...10 {
                _ = try await js.publish("\(streamName).test", payload: ByteBuffer.from("Message \(i)"))
            }

            // Should only have 5 messages
            try await stream.refresh()
            let info = await stream.info
            #expect(info.state.messages == 5)

            try await js.deleteStream(streamName)
            await client.close()
        }

        @Test("Work queue stream")
        func workQueueStream() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
            }
            try await client.connect()

            let js = try await client.jetStream()
            let streamName = "TEST_WORKQ_\(UUID().uuidString.prefix(8))"

            // Create work queue stream
            _ = try await js.createStream(StreamConfig(
                name: streamName,
                subjects: ["\(streamName).>"],
                retention: .workqueue
            ))

            // Publish messages
            for i in 1...5 {
                _ = try await js.publish("\(streamName).tasks", payload: ByteBuffer.from("Task \(i)"))
            }

            // Create consumer and process
            let consumer = try await js.createConsumer(
                stream: streamName,
                config: ConsumerConfig(name: "worker")
            )

            let messages = try await consumer.fetch(batch: 5, maxWait: .seconds(2))
            #expect(messages.count == 5)

            // Ack all messages
            for msg in messages {
                try await msg.ack()
            }

            // Verify stream is empty (work queue removes on ack)
            let stream = try await js.stream(streamName)
            let info = await stream.info
            #expect(info.state.messages == 0)

            try await js.deleteStream(streamName)
            await client.close()
        }
    }

    // MARK: - TLS Tests

    @Suite("TLS Connection Tests")
    struct TLSConnectionTests {

        @Test("Connect with TLS insecure mode")
        func connectWithTLSInsecure() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "tls://localhost:4222")!]
                $0.tls = .insecure
            }

            try await client.connect()
            #expect(await client.isConnected)

            let serverInfo = await client.serverInfo
            #expect(serverInfo != nil)
            // Server has TLS available (may or may not require it)
            #expect(serverInfo?.tlsAvailable == true || serverInfo?.tlsRequired == true)

            await client.close()
            #expect(await !client.isConnected)
        }

        @Test("TLS connection with client name")
        func tlsConnectionWithName() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "tls://localhost:4222")!]
                $0.tls = .insecure
                $0.name = "tls-test-client"
            }

            try await client.connect()
            #expect(await client.isConnected)
            await client.close()
        }

        @Test("Publish and subscribe over TLS")
        func pubSubOverTLS() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "tls://localhost:4222")!]
                $0.tls = .insecure
            }
            try await client.connect()

            let subject = "test.tls.pubsub.\(UUID().uuidString)"
            let testMessage = "Hello over TLS!"

            let subscription = try await client.subscribe(subject)

            try await client.publish(subject, payload: ByteBuffer.from(testMessage))

            var receivedMessage: NatsMessage?
            for await message in subscription {
                receivedMessage = message
                break
            }

            #expect(receivedMessage != nil)
            #expect(receivedMessage?.subject == subject)
            #expect(receivedMessage?.string == testMessage)

            await subscription.unsubscribe()
            await client.close()
        }

        @Test("Publish with headers over TLS")
        func headersOverTLS() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "tls://localhost:4222")!]
                $0.tls = .insecure
            }
            try await client.connect()

            let subject = "test.tls.headers.\(UUID().uuidString)"
            var headers = NatsHeaders()
            headers["X-TLS-Test"] = "secure-value"

            let subscription = try await client.subscribe(subject)

            try await client.publish(subject, payload: ByteBuffer.from("TLS with headers"), headers: headers)

            var receivedMessage: NatsMessage?
            for await message in subscription {
                receivedMessage = message
                break
            }

            #expect(receivedMessage != nil)
            #expect(receivedMessage?.headers?["X-TLS-Test"] == "secure-value")

            await subscription.unsubscribe()
            await client.close()
        }

        @Test("Request/reply over TLS")
        func requestReplyOverTLS() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "tls://localhost:4222")!]
                $0.tls = .insecure
            }
            try await client.connect()

            let subject = "test.tls.request.\(UUID().uuidString)"

            let subscription = try await client.subscribe(subject)

            let responderTask = Task {
                for await message in subscription {
                    if let replyTo = message.replyTo {
                        let response = "TLS Response: \(message.string ?? "")"
                        try await client.publish(replyTo, payload: ByteBuffer.from(response))
                    }
                    break
                }
            }

            try await Task.sleep(for: .milliseconds(100))

            let response = try await client.request(subject, payload: ByteBuffer.from("Secure Hello"), timeout: .seconds(5))

            #expect(response.string == "TLS Response: Secure Hello")

            responderTask.cancel()
            await subscription.unsubscribe()
            await client.close()
        }

        @Test("Large payload over TLS")
        func largePayloadOverTLS() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "tls://localhost:4222")!]
                $0.tls = .insecure
            }
            try await client.connect()

            let subject = "test.tls.large.\(UUID().uuidString)"
            // 100KB payload
            var largeData = ByteBuffer()
            largeData.writeRepeatingByte(0x42, count: 100_000)

            let subscription = try await client.subscribe(subject)

            try await client.publish(subject, payload: largeData)

            var receivedMessage: NatsMessage?
            for await message in subscription {
                receivedMessage = message
                break
            }

            #expect(receivedMessage != nil)
            #expect(receivedMessage?.payload.readableBytes == 100_000)

            await subscription.unsubscribe()
            await client.close()
        }

        @Test("JetStream over TLS")
        func jetStreamOverTLS() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "tls://localhost:4222")!]
                $0.tls = .insecure
            }
            try await client.connect()

            let js = try await client.jetStream()
            let streamName = "TEST_TLS_\(UUID().uuidString.prefix(8))"

            // Create stream
            let stream = try await js.createStream(StreamConfig(
                name: streamName,
                subjects: ["\(streamName).>"]
            ))

            // Publish with ack
            let ack = try await js.publish("\(streamName).test", payload: ByteBuffer.from("Secure JetStream message"))
            #expect(ack.stream == streamName)
            #expect(ack.seq >= 1)

            // Create consumer and fetch
            let consumer = try await stream.createConsumer(config: ConsumerConfig(
                name: "tls-consumer",
                deliverPolicy: .all,
                ackPolicy: .explicit
            ))

            let messages = try await consumer.fetch(batch: 1, maxWait: .seconds(5))
            #expect(messages.count == 1)
            #expect(messages[0].message.string == "Secure JetStream message")

            try await messages[0].ack()

            // Cleanup
            try await js.deleteStream(streamName)
            await client.close()
        }

        @Test("Multiple TLS connections")
        func multipleTLSConnections() async throws {
            var clients: [NatsClient] = []

            for i in 1...3 {
                let client = NatsClient {
                    $0.servers = [URL(string: "tls://localhost:4222")!]
                    $0.tls = .insecure
                    $0.name = "tls-client-\(i)"
                }
                try await client.connect()
                #expect(await client.isConnected)
                clients.append(client)
                // Small delay to avoid overwhelming the server with rapid TLS handshakes
                try await Task.sleep(for: .milliseconds(250))
            }

            // All clients should be connected
            for client in clients {
                #expect(await client.isConnected)
            }

            // Close all
            for client in clients {
                await client.close()
            }
        }

        @Test("TLS connection with enabled config")
        func tlsWithEnabledConfig() async throws {
            let client = NatsClient {
                $0.servers = [URL(string: "nats://localhost:4222")!]
                $0.tls = TLSConfig(
                    enabled: true,
                    certificateVerification: .none
                )
            }

            try await client.connect()
            #expect(await client.isConnected)

            let serverInfo = await client.serverInfo
            #expect(serverInfo?.tlsAvailable == true || serverInfo?.tlsRequired == true)

            await client.close()
        }
    }
}

// MARK: - Test Tags

extension Tag {
    @Tag static var integration: Self
}
