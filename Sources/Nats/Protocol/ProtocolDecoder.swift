// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import NIOCore
import Logging

/// Decodes NATS wire protocol into ServerOp
///
/// Parses the bytes in place through `Span`. The decoder used to read each
/// control line into a `String`, split it into substrings, uppercase the
/// command, and parse headers by splitting a `String` on `"\r\n"` and trimming
/// with Foundation — grapheme-aware string walking and a handful of allocations
/// for every message, which made it nearly all of the event loop's time on a
/// busy connection. Now the line, its fields, the sizes and the headers are
/// located by scanning bytes, and the only allocations are the strings a
/// `ServerOp` actually carries.
final class ProtocolDecoder: ByteToMessageDecoder, Sendable {
    typealias InboundOut = ServerOp

    let logger: Logger

    init(logger: Logger = Logger(label: "nats.decoder")) {
        self.logger = logger
    }

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let op = try decodeOp(from: &buffer) else {
            return .needMoreData
        }
        context.fireChannelRead(wrapInboundOut(op))
        return .continue
    }

    /// Decode one op from the front of `buffer`, consuming it. Returns nil and
    /// leaves `buffer` untouched when the op is not complete yet.
    func decodeOp(from buffer: inout ByteBuffer) throws -> ServerOp? {
        let head: Head
        let lineLength: Int
        do {
            // Everything that needs the bytes happens while the span is alive;
            // the buffer is only moved once it has ended.
            let bytes = buffer.readableBytesUInt8Span
            guard let lineEnd = Wire.firstCRLF(in: bytes, from: 0) else {
                return nil
            }
            lineLength = lineEnd + 2
            head = try Self.parseControlLine(bytes, end: lineEnd, of: buffer)
        }

        switch head {
        case .info(let json):
            buffer.moveReaderIndex(forwardBy: lineLength)
            guard let jsonData = json.data(using: .utf8) else {
                throw ProtocolError.invalidMessage("Invalid INFO JSON encoding")
            }
            return .info(try JSONDecoder().decode(ServerInfo.self, from: jsonData))

        case .msg(let subject, let sid, let reply, let payloadSize):
            // The payload and its trailing CRLF must all be here.
            guard buffer.readableBytes >= lineLength + payloadSize + 2 else {
                return nil
            }
            buffer.moveReaderIndex(forwardBy: lineLength)
            let payload = buffer.readSlice(length: payloadSize)!
            buffer.moveReaderIndex(forwardBy: 2)
            traceMessage("MSG", subject: subject, reply: reply, payload: payload)
            return .msg(subject: subject, sid: sid, reply: reply, payload: payload)

        case .hmsg(let subject, let sid, let reply, let headerSize, let totalSize):
            guard buffer.readableBytes >= lineLength + totalSize + 2 else {
                return nil
            }
            buffer.moveReaderIndex(forwardBy: lineLength)
            let headerBlock = buffer.readSlice(length: headerSize)!
            let headers = Self.parseHeaders(headerBlock)
            let payload = buffer.readSlice(length: totalSize - headerSize)!
            buffer.moveReaderIndex(forwardBy: 2)
            traceMessage("HMSG", subject: subject, reply: reply, payload: payload)
            return .hmsg(subject: subject, sid: sid, reply: reply, headers: headers, payload: payload)

        case .ping:
            buffer.moveReaderIndex(forwardBy: lineLength)
            return .ping

        case .pong:
            buffer.moveReaderIndex(forwardBy: lineLength)
            return .pong

        case .ok:
            buffer.moveReaderIndex(forwardBy: lineLength)
            return .ok

        case .err(let message):
            buffer.moveReaderIndex(forwardBy: lineLength)
            return .err(message)
        }
    }

    private func traceMessage(_ kind: String, subject: String, reply: String?, payload: ByteBuffer) {
        guard logger.logLevel <= .trace else { return }
        let preview = payload.readableBytes > 0
            ? (payload.getString(at: payload.readerIndex, length: min(payload.readableBytes, 2048)) ?? "<\(payload.readableBytes) bytes binary>")
            : "<empty>"
        logger.trace("<<< \(kind) \(subject)\(reply.map { " reply=\($0)" } ?? "") [\(payload.readableBytes)B] \(preview)")
    }

    // MARK: - Control Line

    /// A parsed control line, before its payload (if any) has been read.
    private enum Head {
        case info(json: String)
        case msg(subject: String, sid: String, reply: String?, payloadSize: Int)
        case hmsg(subject: String, sid: String, reply: String?, headerSize: Int, totalSize: Int)
        case ping
        case pong
        case ok
        case err(String)
    }

    /// Parse the control line `bytes[0..<end]`. Strings are copied out of
    /// `buffer`, whose readable bytes `bytes` views.
    private static func parseControlLine(
        _ bytes: Span<UInt8>,
        end: Int,
        of buffer: borrowing ByteBuffer
    ) throws -> Head {
        var fields = Fields()
        Wire.split(bytes, 0..<end, into: &fields)
        guard fields.count > 0 else {
            throw ProtocolError.invalidMessage("Empty protocol line")
        }
        let command = fields[0]

        func string(_ range: Range<Int>) -> String {
            buffer.getString(at: buffer.readerIndex + range.lowerBound, length: range.count)!
        }

        // Commands are case-insensitive on the wire.
        if Wire.matches(bytes, command, "MSG") {
            // MSG <subject> <sid> [reply-to] <#bytes>
            guard fields.count >= 4 else {
                throw ProtocolError.invalidMessage("Invalid MSG format")
            }
            let hasReply = fields.count > 4
            guard let size = Wire.integer(bytes, fields[hasReply ? 4 : 3]) else {
                throw ProtocolError.invalidMessage("Invalid MSG payload size")
            }
            return .msg(
                subject: string(fields[1]),
                sid: string(fields[2]),
                reply: hasReply ? string(fields[3]) : nil,
                payloadSize: size
            )
        }

        if Wire.matches(bytes, command, "HMSG") {
            // HMSG <subject> <sid> [reply-to] <#header bytes> <#total bytes>
            guard fields.count >= 5 else {
                throw ProtocolError.invalidMessage("Invalid HMSG format")
            }
            let hasReply = fields.count > 5
            guard let headerSize = Wire.integer(bytes, fields[hasReply ? 4 : 3]),
                  let totalSize = Wire.integer(bytes, fields[hasReply ? 5 : 4]),
                  headerSize <= totalSize else {
                throw ProtocolError.invalidMessage("Invalid HMSG sizes")
            }
            return .hmsg(
                subject: string(fields[1]),
                sid: string(fields[2]),
                reply: hasReply ? string(fields[3]) : nil,
                headerSize: headerSize,
                totalSize: totalSize
            )
        }

        if Wire.matches(bytes, command, "PING") { return .ping }
        if Wire.matches(bytes, command, "PONG") { return .pong }
        if Wire.matches(bytes, command, "+OK") { return .ok }

        // INFO and -ERR carry the rest of the line after the command.
        let rest = Wire.trimming(bytes, command.upperBound..<end, isStrippable: Wire.isSpace)

        if Wire.matches(bytes, command, "INFO") {
            guard !rest.isEmpty else {
                throw ProtocolError.invalidMessage("INFO missing payload")
            }
            return .info(json: string(rest))
        }

        if Wire.matches(bytes, command, "-ERR") {
            guard !rest.isEmpty else {
                return .err("Unknown error")
            }
            let unquoted = Wire.trimming(bytes, rest) { $0 == UInt8(ascii: "'") || $0 == UInt8(ascii: "\"") }
            return .err(string(unquoted))
        }

        throw ProtocolError.invalidMessage("Unknown command: \(string(command).uppercased())")
    }

    // MARK: - Header Parsing

    /// Parse a header block: `NATS/1.0[ status[ description]]` followed by
    /// `Key: Value` lines, each ended by CRLF.
    static func parseHeaders(_ block: ByteBuffer) -> NatsHeaders {
        var headers = NatsHeaders()
        let bytes = block.readableBytesUInt8Span
        let count = bytes.count

        func string(_ range: Range<Int>) -> String {
            block.getString(at: block.readerIndex + range.lowerBound, length: range.count)!
        }

        var lineStart = 0
        var isFirstLine = true
        while lineStart < count {
            let lineEnd = Wire.firstCRLF(in: bytes, from: lineStart) ?? count
            defer {
                lineStart = lineEnd + 2
                isFirstLine = false
            }

            if isFirstLine {
                // Status line. Anything other than NATS/1.0 carries no status.
                var fields = Fields()
                Wire.split(bytes, lineStart..<lineEnd, into: &fields, maxFields: 2)
                guard fields.count > 0, Wire.matches(bytes, fields[0], "NATS/1.0", caseSensitive: true) else {
                    continue
                }
                if fields.count > 1 {
                    // The description is the rest of the line, spaces and all.
                    let status = fields[1]
                    var statusEnd = status.lowerBound
                    while statusEnd < status.upperBound, !Wire.isSpace(bytes[statusEnd]) {
                        statusEnd += 1
                    }
                    headers.append(NatsHeaders.Keys.status, string(status.lowerBound..<statusEnd))
                    let description = Wire.trimming(bytes, statusEnd..<status.upperBound, isStrippable: Wire.isSpace)
                    if !description.isEmpty {
                        headers.append(NatsHeaders.Keys.description, string(description))
                    }
                }
                continue
            }

            guard let colon = Wire.firstIndex(of: UInt8(ascii: ":"), in: bytes, lineStart..<lineEnd) else {
                continue
            }
            let key = Wire.trimming(bytes, lineStart..<colon, isStrippable: Wire.isSpace)
            guard !key.isEmpty else { continue }
            let value = Wire.trimming(bytes, (colon + 1)..<lineEnd, isStrippable: Wire.isSpace)
            headers.append(string(key), string(value))
        }
        return headers
    }
}

// MARK: - Byte Scanning

/// Up to eight field ranges of a line, stored inline so tokenising a control
/// line allocates nothing. A MSG line has at most five fields, an HMSG six;
/// anything past eight is dropped, as nothing reads it.
struct Fields {
    private var storage: (Range<Int>, Range<Int>, Range<Int>, Range<Int>, Range<Int>, Range<Int>, Range<Int>, Range<Int>)
        = (0..<0, 0..<0, 0..<0, 0..<0, 0..<0, 0..<0, 0..<0, 0..<0)
    private(set) var count = 0

    static let capacity = 8

    subscript(index: Int) -> Range<Int> {
        precondition(index < count)
        switch index {
        case 0: return storage.0
        case 1: return storage.1
        case 2: return storage.2
        case 3: return storage.3
        case 4: return storage.4
        case 5: return storage.5
        case 6: return storage.6
        default: return storage.7
        }
    }

    mutating func append(_ range: Range<Int>) {
        guard count < Self.capacity else { return }
        switch count {
        case 0: storage.0 = range
        case 1: storage.1 = range
        case 2: storage.2 = range
        case 3: storage.3 = range
        case 4: storage.4 = range
        case 5: storage.5 = range
        case 6: storage.6 = range
        default: storage.7 = range
        }
        count += 1
    }
}

/// Byte-level helpers over a `Span`. Offsets are relative to the span.
enum Wire {
    static func isSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
    }

    /// Offset of the first `\r\n` at or after `start`.
    static func firstCRLF(in bytes: Span<UInt8>, from start: Int) -> Int? {
        var index = start
        let last = bytes.count - 1
        while index < last {
            if bytes[index] == 0x0D && bytes[index + 1] == 0x0A {
                return index
            }
            index += 1
        }
        return nil
    }

    static func firstIndex(of byte: UInt8, in bytes: Span<UInt8>, _ range: Range<Int>) -> Int? {
        var index = range.lowerBound
        while index < range.upperBound {
            if bytes[index] == byte {
                return index
            }
            index += 1
        }
        return nil
    }

    /// Split `range` on runs of spaces and tabs. With `maxFields`, the last
    /// field runs to the end of the range.
    static func split(_ bytes: Span<UInt8>, _ range: Range<Int>, into fields: inout Fields, maxFields: Int = Fields.capacity) {
        var index = range.lowerBound
        while index < range.upperBound {
            while index < range.upperBound, isSpace(bytes[index]) {
                index += 1
            }
            guard index < range.upperBound else { return }
            if fields.count == maxFields - 1 {
                fields.append(index..<range.upperBound)
                return
            }
            let start = index
            while index < range.upperBound, !isSpace(bytes[index]) {
                index += 1
            }
            fields.append(start..<index)
        }
    }

    static func trimming(_ bytes: Span<UInt8>, _ range: Range<Int>, isStrippable: (UInt8) -> Bool) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, isStrippable(bytes[lower]) {
            lower += 1
        }
        while upper > lower, isStrippable(bytes[upper - 1]) {
            upper -= 1
        }
        return lower..<upper
    }

    /// Whether `bytes[range]` spells `word`, ignoring ASCII case unless
    /// `caseSensitive`.
    static func matches(_ bytes: Span<UInt8>, _ range: Range<Int>, _ word: StaticString, caseSensitive: Bool = false) -> Bool {
        guard range.count == word.utf8CodeUnitCount else { return false }
        return word.withUTF8Buffer { expected in
            var offset = 0
            while offset < expected.count {
                var actual = bytes[range.lowerBound + offset]
                if !caseSensitive, actual >= UInt8(ascii: "a"), actual <= UInt8(ascii: "z") {
                    actual -= 0x20
                }
                if actual != expected[offset] {
                    return false
                }
                offset += 1
            }
            return true
        }
    }

    /// A non-negative decimal integer spelled by `bytes[range]`, or nil.
    static func integer(_ bytes: Span<UInt8>, _ range: Range<Int>) -> Int? {
        guard !range.isEmpty, range.count <= 18 else { return nil }
        var value = 0
        var index = range.lowerBound
        while index < range.upperBound {
            let digit = bytes[index] &- UInt8(ascii: "0")
            guard digit < 10 else { return nil }
            value = value * 10 + Int(digit)
            index += 1
        }
        return value
    }
}

// MARK: - ByteBuffer Extensions

extension ByteBuffer {
    /// Read a line terminated by \r\n
    mutating func readLine() -> String? {
        let lineEnd: Int
        do {
            guard let end = Wire.firstCRLF(in: readableBytesUInt8Span, from: 0) else {
                return nil
            }
            lineEnd = end
        }
        guard let line = readString(length: lineEnd) else {
            return nil
        }
        // Skip the \r\n
        moveReaderIndex(forwardBy: 2)
        return line
    }
}
