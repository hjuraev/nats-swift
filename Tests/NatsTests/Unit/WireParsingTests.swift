// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
import NIOCore
@testable import Nats

/// Edge cases for the byte-level parsing in `ProtocolDecoder` and `AckSubject`,
/// beyond what `ProtocolDecoderTests` covers through the pipeline.
@Suite("Wire Parsing Tests")
struct WireParsingTests {

    private func decode(_ wire: String) throws -> ServerOp? {
        var buffer = ByteBuffer(string: wire)
        return try ProtocolDecoder().decodeOp(from: &buffer)
    }

    @Test("Fields may be separated by runs of spaces and tabs")
    func mixedSeparators() throws {
        guard case .msg(let subject, let sid, let reply, let payload) = try decode("MSG  foo.bar\t9 \t reply.to 3\r\nabc\r\n") else {
            Issue.record("expected MSG")
            return
        }
        #expect(subject == "foo.bar")
        #expect(sid == "9")
        #expect(reply == "reply.to")
        #expect(payload.readableBytes == 3)
    }

    @Test("A partial frame is not consumed")
    func partialFrameLeavesBufferUntouched() throws {
        var buffer = ByteBuffer(string: "MSG foo 1 10\r\nabc")
        let before = buffer.readerIndex
        #expect(try ProtocolDecoder().decodeOp(from: &buffer) == nil)
        #expect(buffer.readerIndex == before)
    }

    @Test("HMSG whose header size exceeds its total size is rejected")
    func headerLargerThanTotal() {
        #expect(throws: ProtocolError.self) {
            _ = try decode("HMSG foo 1 20 10\r\n")
        }
    }

    @Test("Sizes must be plain digits")
    func signedSizeRejected() {
        #expect(throws: ProtocolError.self) {
            _ = try decode("MSG foo 1 -3\r\n")
        }
    }

    @Test("Status description keeps its inner spaces")
    func statusDescription() {
        let headers = ProtocolDecoder.parseHeaders(ByteBuffer(string: "NATS/1.0 409 Message Size Exceeds MaxBytes\r\n\r\n"))
        #expect(headers.status == 409)
        #expect(headers.statusDescription == "Message Size Exceeds MaxBytes")
    }

    @Test("Header keys and values are trimmed; lines without a colon are skipped")
    func headerLines() {
        let headers = ProtocolDecoder.parseHeaders(ByteBuffer(string: "NATS/1.0\r\n  KV-Operation :\tDEL \r\nnot a header\r\nX-Empty:\r\n\r\n"))
        #expect(headers["KV-Operation"] == "DEL")
        #expect(headers["X-Empty"] == "")
        #expect(headers.count == 2)
        #expect(headers.status == nil)
    }

    @Test("A block without the NATS/1.0 line carries no status")
    func missingVersionLine() {
        let headers = ProtocolDecoder.parseHeaders(ByteBuffer(string: "Weird: first\r\nA: b\r\n\r\n"))
        #expect(headers.status == nil)
        #expect(headers["Weird"] == nil, "the first line is the status line, never a header")
        #expect(headers["A"] == "b")
    }

    @Test("Header names match case-insensitively without allocating, including non-ASCII")
    func headerNameMatching() {
        #expect(NatsHeaders.namesMatch("KV-Operation", "kv-operation"))
        #expect(NatsHeaders.namesMatch("Status", "STATUS"))
        #expect(!NatsHeaders.namesMatch("Status", "Statu"))
        #expect(!NatsHeaders.namesMatch("Status", "Stat_s"))
        #expect(!NatsHeaders.namesMatch("A[", "a{"), "only letters fold")
        #expect(NatsHeaders.namesMatch("Ünïcode", "üNÏCODE"))
        var headers = NatsHeaders()
        headers.append("Nats-Msg-Size", "1")
        #expect(headers["nats-msg-size"] == "1")
        headers["NATS-MSG-SIZE"] = "2"
        #expect(headers.count == 1)
        #expect(headers["Nats-Msg-Size"] == "2")
    }

    @Test("RFC 3339 timestamps parse like ISO8601DateFormatter")
    func rfc3339MatchesFoundation() throws {
        let samples = [
            "2026-09-17T03:19:04.576735Z",
            "2026-09-17T03:19:04Z",
            "2026-09-17T03:19:04.5Z",
            "2026-09-17T03:19:04.123456789Z",
            "1970-01-01T00:00:00Z",
            "2000-02-29T23:59:59.999Z",
            "2026-09-17T08:19:04.25+05:00",
            "2026-09-16T22:19:04-05:00",
        ]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        for sample in samples {
            let fast = try #require(RFC3339.fastDate(from: sample), "fast path rejected \(sample)")
            let reference = try #require(formatter.date(from: sample) ?? plain.date(from: sample))
            // The formatter keeps milliseconds; the fast path keeps nanoseconds.
            #expect(abs(fast.timeIntervalSince(reference)) < 0.001, "\(sample): \(fast) vs \(reference)")
        }
    }

    @Test("Malformed timestamps are rejected by the fast path")
    func rfc3339Rejects() {
        for sample in ["", "2026-09-17", "2026-13-01T00:00:00Z", "2026-09-17T24:00:00Z", "2026-09-17T03:19:04", "2026-09-17T03:19:04.Z", "2026-09-17T03:19:04Zjunk"] {
            #expect(RFC3339.fastDate(from: sample) == nil, "accepted \(sample)")
        }
    }

    @Test("Ack subject fields")
    func ackSubject() throws {
        let subject = "$JS.ACK.KV_bucket.watcher.2.1234.567.1789615116499918000.42"
        let ack = try #require(AckSubject(subject))
        #expect(String(subject[ack.stream]) == "KV_bucket")
        #expect(String(subject[ack.consumer]) == "watcher")
        #expect(ack.numDelivered == 2)
        #expect(ack.streamSequence == 1234)
        #expect(ack.consumerSequence == 567)
        #expect(ack.timestampNanos == 1_789_615_116_499_918_000)
        #expect(ack.numPending == 42)
        #expect(ack.string(ack.stream, in: subject, reusing: "KV_bucket") == "KV_bucket")
        #expect(ack.string(ack.consumer, in: subject, reusing: "other") == "watcher")
    }

    @Test("Ack subjects that are not JetStream acks are rejected")
    func notAnAck() {
        #expect(AckSubject("$JS.API.CONSUMER.INFO.a.b.c.d.e") == nil)
        #expect(AckSubject("_INBOX.abc.1") == nil)
        #expect(AckSubject("$JS.ACK.stream.consumer.1.2.3") == nil, "too few fields")
    }

    @Test("Malformed numbers read as zero, as the split-based parser did")
    func malformedNumbers() throws {
        let ack = try #require(AckSubject("$JS.ACK.s.c.x.2.3.notatime.5"))
        #expect(ack.numDelivered == 0)
        #expect(ack.streamSequence == 2)
        #expect(ack.timestampNanos == nil)
        #expect(ack.numPending == 5)
    }
}
