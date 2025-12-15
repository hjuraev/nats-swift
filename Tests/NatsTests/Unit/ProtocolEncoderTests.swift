// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import NIOCore
@testable import Nats

@Suite("ProtocolEncoder Tests")
struct ProtocolEncoderTests {

    let allocator = ByteBufferAllocator()
    let encoder = ProtocolEncoder()

    // MARK: - PING/PONG Tests

    @Test("Encode PING")
    func encodePing() throws {
        var buffer = allocator.buffer(capacity: 64)
        try encoder.encode(data: .ping, out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string == "PING\r\n")
    }

    @Test("Encode PONG")
    func encodePong() throws {
        var buffer = allocator.buffer(capacity: 64)
        try encoder.encode(data: .pong, out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string == "PONG\r\n")
    }

    // MARK: - CONNECT Tests

    @Test("Encode CONNECT with minimal info")
    func encodeConnectMinimal() throws {
        var buffer = allocator.buffer(capacity: 512)
        let info = ConnectInfo()
        try encoder.encode(data: .connect(info), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)!
        #expect(string.hasPrefix("CONNECT "))
        #expect(string.hasSuffix("\r\n"))

        // Extract and verify JSON
        let jsonStart = string.index(string.startIndex, offsetBy: 8)
        let jsonEnd = string.index(string.endIndex, offsetBy: -2)
        let jsonString = String(string[jsonStart..<jsonEnd])

        #expect(jsonString.contains("\"lang\":\"swift\""))
        #expect(jsonString.contains("\"headers\":true"))
        #expect(jsonString.contains("\"protocol\":1"))
    }

    @Test("Encode CONNECT with auth token")
    func encodeConnectWithToken() throws {
        var buffer = allocator.buffer(capacity: 512)
        let info = ConnectInfo(authToken: "secret-token")
        try encoder.encode(data: .connect(info), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)!
        #expect(string.contains("\"auth_token\":\"secret-token\""))
    }

    @Test("Encode CONNECT with user/pass")
    func encodeConnectWithUserPass() throws {
        var buffer = allocator.buffer(capacity: 512)
        let info = ConnectInfo(user: "admin", pass: "password123")
        try encoder.encode(data: .connect(info), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)!
        #expect(string.contains("\"user\":\"admin\""))
        #expect(string.contains("\"pass\":\"password123\""))
    }

    @Test("Encode CONNECT with client name")
    func encodeConnectWithName() throws {
        var buffer = allocator.buffer(capacity: 512)
        let info = ConnectInfo(name: "my-client")
        try encoder.encode(data: .connect(info), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)!
        #expect(string.contains("\"name\":\"my-client\""))
    }

    @Test("Encode CONNECT with NKey")
    func encodeConnectWithNKey() throws {
        var buffer = allocator.buffer(capacity: 512)
        let info = ConnectInfo(nkey: "UABC123", sig: "base64sig")
        try encoder.encode(data: .connect(info), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)!
        #expect(string.contains("\"nkey\":\"UABC123\""))
        #expect(string.contains("\"sig\":\"base64sig\""))
    }

    @Test("Encode CONNECT with JWT")
    func encodeConnectWithJWT() throws {
        var buffer = allocator.buffer(capacity: 512)
        let info = ConnectInfo(jwt: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
        try encoder.encode(data: .connect(info), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)!
        #expect(string.contains("\"jwt\":\"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9\""))
    }

    // MARK: - SUB Tests

    @Test("Encode SUB without queue group")
    func encodeSubWithoutQueue() throws {
        var buffer = allocator.buffer(capacity: 64)
        try encoder.encode(data: .subscribe(sid: "1", subject: "test.subject", queue: nil), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string == "SUB test.subject 1\r\n")
    }

    @Test("Encode SUB with queue group")
    func encodeSubWithQueue() throws {
        var buffer = allocator.buffer(capacity: 64)
        try encoder.encode(data: .subscribe(sid: "1", subject: "test.subject", queue: "workers"), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string == "SUB test.subject workers 1\r\n")
    }

    @Test("Encode SUB with wildcard subject")
    func encodeSubWithWildcard() throws {
        var buffer = allocator.buffer(capacity: 64)
        try encoder.encode(data: .subscribe(sid: "sub-123", subject: "events.>", queue: nil), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string == "SUB events.> sub-123\r\n")
    }

    @Test("Encode SUB with complex sid")
    func encodeSubWithComplexSid() throws {
        var buffer = allocator.buffer(capacity: 64)
        try encoder.encode(data: .subscribe(sid: "sub_123_abc", subject: "foo.bar", queue: nil), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string == "SUB foo.bar sub_123_abc\r\n")
    }

    // MARK: - UNSUB Tests

    @Test("Encode UNSUB without max")
    func encodeUnsubWithoutMax() throws {
        var buffer = allocator.buffer(capacity: 64)
        try encoder.encode(data: .unsubscribe(sid: "1", max: nil), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string == "UNSUB 1\r\n")
    }

    @Test("Encode UNSUB with max")
    func encodeUnsubWithMax() throws {
        var buffer = allocator.buffer(capacity: 64)
        try encoder.encode(data: .unsubscribe(sid: "1", max: 10), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string == "UNSUB 1 10\r\n")
    }

    @Test("Encode UNSUB with zero max")
    func encodeUnsubWithZeroMax() throws {
        var buffer = allocator.buffer(capacity: 64)
        try encoder.encode(data: .unsubscribe(sid: "sub-1", max: 0), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string == "UNSUB sub-1 0\r\n")
    }

    @Test("Encode UNSUB with large max")
    func encodeUnsubWithLargeMax() throws {
        var buffer = allocator.buffer(capacity: 64)
        try encoder.encode(data: .unsubscribe(sid: "1", max: 1000000), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string == "UNSUB 1 1000000\r\n")
    }

    // MARK: - PUB Tests

    @Test("Encode PUB without reply")
    func encodePubWithoutReply() throws {
        var buffer = allocator.buffer(capacity: 128)
        var payload = allocator.buffer(capacity: 16)
        payload.writeString("hello")

        try encoder.encode(data: .publish(subject: "test", reply: nil, headers: nil, payload: payload), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string == "PUB test 5\r\nhello\r\n")
    }

    @Test("Encode PUB with reply")
    func encodePubWithReply() throws {
        var buffer = allocator.buffer(capacity: 128)
        var payload = allocator.buffer(capacity: 16)
        payload.writeString("hello")

        try encoder.encode(data: .publish(subject: "test", reply: "_INBOX.123", headers: nil, payload: payload), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string == "PUB test _INBOX.123 5\r\nhello\r\n")
    }

    @Test("Encode PUB with empty payload")
    func encodePubEmptyPayload() throws {
        var buffer = allocator.buffer(capacity: 128)
        let payload = allocator.buffer(capacity: 0)

        try encoder.encode(data: .publish(subject: "test", reply: nil, headers: nil, payload: payload), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string == "PUB test 0\r\n\r\n")
    }

    @Test("Encode PUB with large payload")
    func encodePubLargePayload() throws {
        var buffer = allocator.buffer(capacity: 2048)
        var payload = allocator.buffer(capacity: 1000)
        payload.writeString(String(repeating: "X", count: 1000))

        try encoder.encode(data: .publish(subject: "test", reply: nil, headers: nil, payload: payload), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)!
        #expect(string.hasPrefix("PUB test 1000\r\n"))
        #expect(string.contains(String(repeating: "X", count: 1000)))
        #expect(string.hasSuffix("\r\n"))
    }

    @Test("Encode PUB with binary payload")
    func encodePubBinaryPayload() throws {
        var buffer = allocator.buffer(capacity: 128)
        var payload = allocator.buffer(capacity: 8)
        payload.writeBytes([0x00, 0x01, 0x02, 0xFF, 0xFE])

        try encoder.encode(data: .publish(subject: "test", reply: nil, headers: nil, payload: payload), out: &buffer)

        // Read the header line (12 bytes: "PUB test 5\r\n")
        let headerLine = buffer.readString(length: 12)
        #expect(headerLine == "PUB test 5\r\n")

        // Read the binary payload
        let payloadBytes = buffer.readBytes(length: 5)
        #expect(payloadBytes == [0x00, 0x01, 0x02, 0xFF, 0xFE])

        // Verify trailing CRLF
        let trailing = buffer.readString(length: 2)
        #expect(trailing == "\r\n")
    }

    // MARK: - HPUB Tests

    @Test("Encode HPUB without reply")
    func encodeHPubWithoutReply() throws {
        var buffer = allocator.buffer(capacity: 256)
        var payload = allocator.buffer(capacity: 16)
        payload.writeString("hello")

        var headers = NatsHeaders()
        headers["X-Custom"] = "value"

        try encoder.encode(data: .publish(subject: "test", reply: nil, headers: headers, payload: payload), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)!
        #expect(string.hasPrefix("HPUB test"))
        #expect(string.contains("NATS/1.0\r\n"))
        #expect(string.contains("X-Custom: value\r\n"))
        #expect(string.hasSuffix("hello\r\n"))
    }

    @Test("Encode HPUB with reply")
    func encodeHPubWithReply() throws {
        var buffer = allocator.buffer(capacity: 256)
        var payload = allocator.buffer(capacity: 16)
        payload.writeString("hello")

        var headers = NatsHeaders()
        headers["X-Custom"] = "value"

        try encoder.encode(data: .publish(subject: "test", reply: "_INBOX.123", headers: headers, payload: payload), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)!
        #expect(string.hasPrefix("HPUB test _INBOX.123"))
    }

    @Test("Encode HPUB with multiple headers")
    func encodeHPubMultipleHeaders() throws {
        var buffer = allocator.buffer(capacity: 256)
        var payload = allocator.buffer(capacity: 16)
        payload.writeString("hello")

        var headers = NatsHeaders()
        headers["X-First"] = "first"
        headers["X-Second"] = "second"
        headers["X-Third"] = "third"

        try encoder.encode(data: .publish(subject: "test", reply: nil, headers: headers, payload: payload), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)!
        #expect(string.contains("X-First: first\r\n"))
        #expect(string.contains("X-Second: second\r\n"))
        #expect(string.contains("X-Third: third\r\n"))
    }

    @Test("Encode HPUB header size calculation")
    func encodeHPubHeaderSizeCalculation() throws {
        var buffer = allocator.buffer(capacity: 256)
        var payload = allocator.buffer(capacity: 16)
        payload.writeString("12345")  // 5 bytes

        var headers = NatsHeaders()
        headers["Key"] = "Val"

        try encoder.encode(data: .publish(subject: "test", reply: nil, headers: headers, payload: payload), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)!
        let lines = string.split(separator: "\r\n")
        let parts = lines[0].split(separator: " ")

        let headerSize = Int(parts[2])!
        let totalSize = Int(parts[3])!

        // Total = header bytes + payload bytes (5)
        #expect(totalSize == headerSize + 5)
    }

    @Test("Empty headers use PUB instead of HPUB")
    func emptyHeadersUsePUB() throws {
        var buffer = allocator.buffer(capacity: 128)
        var payload = allocator.buffer(capacity: 16)
        payload.writeString("hello")

        let headers = NatsHeaders()  // Empty

        try encoder.encode(data: .publish(subject: "test", reply: nil, headers: headers, payload: payload), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string?.hasPrefix("PUB ") == true)
    }

    @Test("Nil headers use PUB")
    func nilHeadersUsePUB() throws {
        var buffer = allocator.buffer(capacity: 128)
        var payload = allocator.buffer(capacity: 16)
        payload.writeString("hello")

        try encoder.encode(data: .publish(subject: "test", reply: nil, headers: nil, payload: payload), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string?.hasPrefix("PUB ") == true)
    }

    @Test("Encode HPUB with empty payload")
    func encodeHPubEmptyPayload() throws {
        var buffer = allocator.buffer(capacity: 256)
        let payload = allocator.buffer(capacity: 0)

        var headers = NatsHeaders()
        headers["X-Test"] = "value"

        try encoder.encode(data: .publish(subject: "test", reply: nil, headers: headers, payload: payload), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)!
        #expect(string.hasPrefix("HPUB test"))

        // Parse sizes
        let lines = string.split(separator: "\r\n")
        let parts = lines[0].split(separator: " ")
        let headerSize = Int(parts[2])!
        let totalSize = Int(parts[3])!

        // With empty payload, total should equal header size
        #expect(totalSize == headerSize)
    }

    // MARK: - Special Characters Tests

    @Test("Encode PUB with subject containing dots")
    func encodePubWithDottedSubject() throws {
        var buffer = allocator.buffer(capacity: 128)
        var payload = allocator.buffer(capacity: 16)
        payload.writeString("test")

        try encoder.encode(data: .publish(subject: "foo.bar.baz", reply: nil, headers: nil, payload: payload), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)
        #expect(string == "PUB foo.bar.baz 4\r\ntest\r\n")
    }

    @Test("Encode HPUB with header containing special characters")
    func encodeHPubWithSpecialCharsInHeader() throws {
        var buffer = allocator.buffer(capacity: 256)
        var payload = allocator.buffer(capacity: 16)
        payload.writeString("test")

        var headers = NatsHeaders()
        headers["X-Special"] = "value with spaces and: colon"

        try encoder.encode(data: .publish(subject: "test", reply: nil, headers: headers, payload: payload), out: &buffer)

        let string = buffer.readString(length: buffer.readableBytes)!
        #expect(string.contains("X-Special: value with spaces and: colon\r\n"))
    }
}
