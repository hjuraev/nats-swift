// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import NIOCore
import NIOEmbedded
@testable import Nats

@Suite("ProtocolDecoder Tests")
struct ProtocolDecoderTests {

    // MARK: - Test Helper

    func makeChannel() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(ByteToMessageHandler(ProtocolDecoder())).wait()
        return channel
    }

    // MARK: - INFO Tests

    @Test("Decode INFO with minimal fields")
    func decodeInfoMinimal() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        let infoJSON = """
        {"server_id":"test","server_name":"test-server","version":"2.10.0","proto":1,"host":"localhost","port":4222,"headers":true,"max_payload":1048576}
        """
        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeString("INFO \(infoJSON)\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .info(let serverInfo) = op else {
            Issue.record("Expected INFO, got \(String(describing: op))")
            return
        }

        #expect(serverInfo.serverId == "test")
        #expect(serverInfo.serverName == "test-server")
        #expect(serverInfo.version == "2.10.0")
        #expect(serverInfo.proto == 1)
        #expect(serverInfo.host == "localhost")
        #expect(serverInfo.port == 4222)
        #expect(serverInfo.headers == true)
        #expect(serverInfo.maxPayload == 1048576)
    }

    @Test("Decode INFO with auth required and nonce")
    func decodeInfoWithAuth() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        let infoJSON = """
        {"server_id":"test","server_name":"test","version":"2.10.0","proto":1,"host":"localhost","port":4222,"headers":true,"max_payload":1048576,"auth_required":true,"nonce":"abc123xyz"}
        """
        var buffer = channel.allocator.buffer(capacity: 512)
        buffer.writeString("INFO \(infoJSON)\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .info(let serverInfo) = op else {
            Issue.record("Expected INFO")
            return
        }

        #expect(serverInfo.authRequired == true)
        #expect(serverInfo.nonce == "abc123xyz")
    }

    @Test("Decode INFO with JetStream")
    func decodeInfoWithJetStream() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        let infoJSON = """
        {"server_id":"test","server_name":"test","version":"2.10.0","proto":1,"host":"localhost","port":4222,"headers":true,"max_payload":1048576,"jetstream":true}
        """
        var buffer = channel.allocator.buffer(capacity: 512)
        buffer.writeString("INFO \(infoJSON)\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .info(let serverInfo) = op else {
            Issue.record("Expected INFO")
            return
        }

        #expect(serverInfo.jetstream == true)
    }

    @Test("Decode INFO with TLS fields")
    func decodeInfoWithTLS() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        let infoJSON = """
        {"server_id":"test","server_name":"test","version":"2.10.0","proto":1,"host":"localhost","port":4222,"headers":true,"max_payload":1048576,"tls_required":true,"tls_available":true}
        """
        var buffer = channel.allocator.buffer(capacity: 512)
        buffer.writeString("INFO \(infoJSON)\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .info(let serverInfo) = op else {
            Issue.record("Expected INFO")
            return
        }

        #expect(serverInfo.tlsRequired == true)
        #expect(serverInfo.tlsAvailable == true)
    }

    // MARK: - MSG Tests

    @Test("Decode MSG without reply")
    func decodeMsgWithoutReply() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("MSG test.subject 1 5\r\nhello\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .msg(let subject, let sid, let reply, let payload) = op else {
            Issue.record("Expected MSG")
            return
        }

        #expect(subject == "test.subject")
        #expect(sid == "1")
        #expect(reply == nil)
        #expect(payload.readableBytes == 5)
        #expect(payload.getString(at: payload.readerIndex, length: 5) == "hello")
    }

    @Test("Decode MSG with reply")
    func decodeMsgWithReply() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 128)
        buffer.writeString("MSG test.subject 1 _INBOX.123 5\r\nhello\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .msg(let subject, let sid, let reply, _) = op else {
            Issue.record("Expected MSG")
            return
        }

        #expect(subject == "test.subject")
        #expect(sid == "1")
        #expect(reply == "_INBOX.123")
    }

    @Test("Decode MSG with empty payload")
    func decodeMsgEmptyPayload() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("MSG test.subject 1 0\r\n\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .msg(_, _, _, let payload) = op else {
            Issue.record("Expected MSG")
            return
        }

        #expect(payload.readableBytes == 0)
    }

    @Test("Decode MSG with large payload")
    func decodeMsgLargePayload() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        let payloadData = String(repeating: "X", count: 10000)
        var buffer = channel.allocator.buffer(capacity: 11000)
        buffer.writeString("MSG test.subject 1 10000\r\n\(payloadData)\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .msg(_, _, _, let payload) = op else {
            Issue.record("Expected MSG")
            return
        }

        #expect(payload.readableBytes == 10000)
    }

    @Test("Decode MSG with dotted subject")
    func decodeMsgDottedSubject() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("MSG foo.bar.baz 123 4\r\ntest\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .msg(let subject, let sid, _, _) = op else {
            Issue.record("Expected MSG")
            return
        }

        #expect(subject == "foo.bar.baz")
        #expect(sid == "123")
    }

    // MARK: - HMSG Tests

    @Test("Decode HMSG without reply")
    func decodeHMsgWithoutReply() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        // Headers: "NATS/1.0\r\nX-Custom: value\r\n\r\n" = 10 + 17 + 2 = 29 bytes
        // Payload: "hello" = 5 bytes
        // Total: 34 bytes
        var buffer = channel.allocator.buffer(capacity: 128)
        buffer.writeString("HMSG test.subject 1 29 34\r\nNATS/1.0\r\nX-Custom: value\r\n\r\nhello\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .hmsg(let subject, let sid, let reply, let headers, let payload) = op else {
            Issue.record("Expected HMSG, got \(String(describing: op))")
            return
        }

        #expect(subject == "test.subject")
        #expect(sid == "1")
        #expect(reply == nil)
        #expect(headers["X-Custom"] == "value")
        #expect(payload.readableBytes == 5)
    }

    @Test("Decode HMSG with reply")
    func decodeHMsgWithReply() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        // Headers: "NATS/1.0\r\nKey: val\r\n\r\n" = 10 + 10 + 2 = 22 bytes
        // Payload: "hello" = 5 bytes
        // Total: 27 bytes
        var buffer = channel.allocator.buffer(capacity: 128)
        buffer.writeString("HMSG test.subject 1 _INBOX.123 22 27\r\nNATS/1.0\r\nKey: val\r\n\r\nhello\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .hmsg(_, _, let reply, let headers, _) = op else {
            Issue.record("Expected HMSG")
            return
        }

        #expect(reply == "_INBOX.123")
        #expect(headers["Key"] == "val")
    }

    @Test("Decode HMSG with status 404")
    func decodeHMsgWithStatus404() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        // NATS/1.0 404 No Messages\r\n\r\n = 27 bytes
        var buffer = channel.allocator.buffer(capacity: 128)
        buffer.writeString("HMSG test.subject 1 27 27\r\nNATS/1.0 404 No Messages\r\n\r\n\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .hmsg(_, _, _, let headers, _) = op else {
            Issue.record("Expected HMSG")
            return
        }

        #expect(headers.status == 404)
        #expect(headers.isNoMessages == true)
    }

    @Test("Decode HMSG with status 408")
    func decodeHMsgWithStatus408() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        // Headers: "NATS/1.0 408 Timeout\r\n\r\n" = 22 + 2 = 24 bytes
        // No payload, total = 24 bytes
        var buffer = channel.allocator.buffer(capacity: 128)
        buffer.writeString("HMSG test.subject 1 24 24\r\nNATS/1.0 408 Timeout\r\n\r\n\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .hmsg(_, _, _, let headers, _) = op else {
            Issue.record("Expected HMSG")
            return
        }

        #expect(headers.status == 408)
        #expect(headers.isTimeout == true)
    }

    @Test("Decode HMSG with status 503")
    func decodeHMsgWithStatus503() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        // Headers: "NATS/1.0 503 No Responders\r\n\r\n" = 28 + 2 = 30 bytes
        // No payload, total = 30 bytes
        var buffer = channel.allocator.buffer(capacity: 128)
        buffer.writeString("HMSG test.subject 1 30 30\r\nNATS/1.0 503 No Responders\r\n\r\n\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .hmsg(_, _, _, let headers, _) = op else {
            Issue.record("Expected HMSG")
            return
        }

        #expect(headers.status == 503)
        #expect(headers.isNoResponders == true)
    }

    @Test("Decode HMSG with multiple headers")
    func decodeHMsgMultipleHeaders() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        // Headers: "NATS/1.0\r\nX-First: one\r\nX-Second: two\r\n\r\n" = 10 + 14 + 15 + 2 = 41 bytes
        // Payload: "hello" = 5 bytes
        // Total: 46 bytes
        var buffer = channel.allocator.buffer(capacity: 128)
        buffer.writeString("HMSG test 1 41 46\r\nNATS/1.0\r\nX-First: one\r\nX-Second: two\r\n\r\nhello\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .hmsg(_, _, _, let headers, _) = op else {
            Issue.record("Expected HMSG")
            return
        }

        #expect(headers["X-First"] == "one")
        #expect(headers["X-Second"] == "two")
    }

    // MARK: - PING/PONG Tests

    @Test("Decode PING")
    func decodePing() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeString("PING\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .ping = op else {
            Issue.record("Expected PING")
            return
        }
    }

    @Test("Decode PONG")
    func decodePong() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeString("PONG\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .pong = op else {
            Issue.record("Expected PONG")
            return
        }
    }

    // MARK: - OK/ERR Tests

    @Test("Decode +OK")
    func decodeOK() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeString("+OK\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .ok = op else {
            Issue.record("Expected OK")
            return
        }
    }

    @Test("Decode -ERR with quoted message")
    func decodeErrQuoted() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("-ERR 'Authorization Violation'\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .err(let msg) = op else {
            Issue.record("Expected ERR")
            return
        }

        #expect(msg == "Authorization Violation")
    }

    @Test("Decode -ERR with double-quoted message")
    func decodeErrDoubleQuoted() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("-ERR \"Unknown Protocol Operation\"\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .err(let msg) = op else {
            Issue.record("Expected ERR")
            return
        }

        #expect(msg == "Unknown Protocol Operation")
    }

    // MARK: - Partial Data Tests

    @Test("Partial message waits for more data")
    func partialMessage() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        // Write incomplete MSG (missing payload)
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("MSG test.subject 1 100\r\npartial")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        // Should not have decoded anything yet
        #expect(op == nil)
    }

    @Test("Complete partial message with additional data")
    func completePartialMessage() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        // Send partial MSG
        var buffer1 = channel.allocator.buffer(capacity: 64)
        buffer1.writeString("MSG test.subject 1 10\r\nhell")
        try channel.writeInbound(buffer1)

        // Should not complete yet
        #expect(try channel.readInbound(as: ServerOp.self) == nil)

        // Send rest
        var buffer2 = channel.allocator.buffer(capacity: 64)
        buffer2.writeString("o-test\r\n")
        try channel.writeInbound(buffer2)

        // Now should complete
        let op = try channel.readInbound(as: ServerOp.self)
        guard case .msg(_, _, _, let payload) = op else {
            Issue.record("Expected MSG")
            return
        }
        #expect(payload.readableBytes == 10)
    }

    @Test("Partial INFO waits for CRLF")
    func partialInfoWaitsForCRLF() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        // Write INFO without CRLF
        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeString("INFO {\"server_id\":\"test\",\"server_name\":\"test\",\"version\":\"2.10.0\",\"proto\":1,\"host\":\"localhost\",\"port\":4222,\"headers\":true,\"max_payload\":1048576}")
        try channel.writeInbound(buffer)

        // Should not decode yet
        #expect(try channel.readInbound(as: ServerOp.self) == nil)

        // Add CRLF
        var buffer2 = channel.allocator.buffer(capacity: 4)
        buffer2.writeString("\r\n")
        try channel.writeInbound(buffer2)

        // Now should decode
        let op = try channel.readInbound(as: ServerOp.self)
        guard case .info = op else {
            Issue.record("Expected INFO")
            return
        }
    }

    // MARK: - Multiple Messages Tests

    @Test("Decode multiple messages in one buffer")
    func decodeMultipleMessages() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 128)
        buffer.writeString("PING\r\nPONG\r\n+OK\r\n")

        try channel.writeInbound(buffer)

        let op1 = try channel.readInbound(as: ServerOp.self)
        guard case .ping = op1 else {
            Issue.record("Expected PING")
            return
        }

        let op2 = try channel.readInbound(as: ServerOp.self)
        guard case .pong = op2 else {
            Issue.record("Expected PONG")
            return
        }

        let op3 = try channel.readInbound(as: ServerOp.self)
        guard case .ok = op3 else {
            Issue.record("Expected OK")
            return
        }
    }

    @Test("Decode MSG followed by PING")
    func decodeMsgFollowedByPing() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 128)
        buffer.writeString("MSG test 1 5\r\nhello\r\nPING\r\n")

        try channel.writeInbound(buffer)

        let op1 = try channel.readInbound(as: ServerOp.self)
        guard case .msg = op1 else {
            Issue.record("Expected MSG")
            return
        }

        let op2 = try channel.readInbound(as: ServerOp.self)
        guard case .ping = op2 else {
            Issue.record("Expected PING")
            return
        }
    }

    // MARK: - Error Cases

    @Test("Invalid command throws error")
    func invalidCommand() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("INVALID command\r\n")

        #expect(throws: ProtocolError.self) {
            try channel.writeInbound(buffer)
            _ = try channel.readInbound(as: ServerOp.self)
        }
    }

    @Test("Invalid MSG format throws error - missing size")
    func invalidMsgMissingSize() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("MSG incomplete\r\n")

        #expect(throws: ProtocolError.self) {
            try channel.writeInbound(buffer)
            _ = try channel.readInbound(as: ServerOp.self)
        }
    }

    @Test("Invalid MSG with non-numeric size throws error")
    func invalidMsgNonNumericSize() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("MSG test 1 abc\r\n")

        #expect(throws: ProtocolError.self) {
            try channel.writeInbound(buffer)
            _ = try channel.readInbound(as: ServerOp.self)
        }
    }

    @Test("INFO missing payload throws error")
    func infoMissingPayload() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("INFO\r\n")

        #expect(throws: ProtocolError.self) {
            try channel.writeInbound(buffer)
            _ = try channel.readInbound(as: ServerOp.self)
        }
    }

    @Test("Invalid HMSG format throws error")
    func invalidHMsgFormat() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("HMSG test 1\r\n")  // Missing sizes

        #expect(throws: ProtocolError.self) {
            try channel.writeInbound(buffer)
            _ = try channel.readInbound(as: ServerOp.self)
        }
    }

    // MARK: - Case Insensitivity Tests

    @Test("Lowercase command works (ping)")
    func lowercasePing() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeString("ping\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .ping = op else {
            Issue.record("Expected PING")
            return
        }
    }

    @Test("Mixed case command works (Pong)")
    func mixedCasePong() throws {
        let channel = try makeChannel()
        defer { try? channel.finish() }

        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeString("Pong\r\n")

        try channel.writeInbound(buffer)
        let op = try channel.readInbound(as: ServerOp.self)

        guard case .pong = op else {
            Issue.record("Expected PONG")
            return
        }
    }
}

// MARK: - ByteBuffer.readLine Tests

@Suite("ByteBuffer.readLine Tests")
struct ByteBufferReadLineTests {

    let allocator = ByteBufferAllocator()

    @Test("readLine returns nil for incomplete line")
    func readLineIncomplete() {
        var buffer = allocator.buffer(capacity: 32)
        buffer.writeString("no terminator")

        let line = buffer.readLine()
        #expect(line == nil)
    }

    @Test("readLine returns line without CRLF")
    func readLineComplete() {
        var buffer = allocator.buffer(capacity: 32)
        buffer.writeString("hello\r\n")

        let line = buffer.readLine()
        #expect(line == "hello")
    }

    @Test("readLine advances reader index past CRLF")
    func readLineAdvancesIndex() {
        var buffer = allocator.buffer(capacity: 64)
        buffer.writeString("first\r\nsecond\r\n")

        let first = buffer.readLine()
        #expect(first == "first")

        let second = buffer.readLine()
        #expect(second == "second")
    }

    @Test("readLine handles empty line")
    func readLineEmpty() {
        var buffer = allocator.buffer(capacity: 32)
        buffer.writeString("\r\n")

        let line = buffer.readLine()
        #expect(line == "")
    }

    @Test("readLine with only CR returns nil")
    func readLineOnlyCR() {
        var buffer = allocator.buffer(capacity: 32)
        buffer.writeString("hello\r")

        let line = buffer.readLine()
        #expect(line == nil)
    }

    @Test("readLine with only LF returns nil")
    func readLineOnlyLF() {
        var buffer = allocator.buffer(capacity: 32)
        buffer.writeString("hello\n")

        let line = buffer.readLine()
        #expect(line == nil)
    }
}
