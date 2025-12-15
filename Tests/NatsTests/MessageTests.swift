// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
@testable import Nats

@Suite("NatsMessage Tests")
struct MessageTests {

    @Test("Message creation")
    func messageCreation() {
        let payload = "Hello, World!".data(using: .utf8)!
        let message = NatsMessage(
            subject: "test.subject",
            replyTo: "reply.subject",
            headers: ["X-Test": "value"],
            payload: payload
        )

        #expect(message.subject == "test.subject")
        #expect(message.replyTo == "reply.subject")
        #expect(message.headers?["X-Test"] == "value")
        #expect(message.payload == payload)
    }

    @Test("Message string payload")
    func stringPayload() {
        let message = NatsMessage(
            subject: "test",
            payload: "Hello".data(using: .utf8)!
        )

        #expect(message.string == "Hello")
    }

    @Test("Message bytes payload")
    func bytesPayload() {
        let bytes: [UInt8] = [0x01, 0x02, 0x03]
        let message = NatsMessage(
            subject: "test",
            payload: Data(bytes)
        )

        #expect(message.bytes == bytes)
    }

    @Test("Message JSON decoding")
    func jsonDecoding() throws {
        struct TestData: Codable, Equatable {
            let name: String
            let value: Int
        }

        let data = TestData(name: "test", value: 42)
        let jsonData = try JSONEncoder().encode(data)

        let message = NatsMessage(
            subject: "test",
            payload: jsonData
        )

        let decoded = try message.decode(TestData.self)
        #expect(decoded == data)
    }

    @Test("Message empty check")
    func emptyCheck() {
        let emptyMessage = NatsMessage(subject: "test", payload: Data())
        #expect(emptyMessage.isEmpty)
        #expect(emptyMessage.size == 0)

        let nonEmptyMessage = NatsMessage(subject: "test", payload: Data([0x01]))
        #expect(!nonEmptyMessage.isEmpty)
        #expect(nonEmptyMessage.size == 1)
    }

    @Test("Message equality")
    func equality() {
        let payload = "test".data(using: .utf8)!

        let msg1 = NatsMessage(subject: "test", payload: payload)
        let msg2 = NatsMessage(subject: "test", payload: payload)
        let msg3 = NatsMessage(subject: "other", payload: payload)

        #expect(msg1 == msg2)
        #expect(msg1 != msg3)
    }

    @Test("Message description")
    func description() {
        let shortMessage = NatsMessage(
            subject: "test",
            payload: "short".data(using: .utf8)!
        )
        #expect(shortMessage.description.contains("test"))
        #expect(shortMessage.description.contains("short"))

        let longMessage = NatsMessage(
            subject: "test",
            payload: String(repeating: "a", count: 100).data(using: .utf8)!
        )
        #expect(longMessage.description.contains("..."))
    }
}
