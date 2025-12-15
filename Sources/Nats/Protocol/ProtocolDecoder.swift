// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import NIOCore

/// Decodes NATS wire protocol into ServerOp
final class ProtocolDecoder: ByteToMessageDecoder, Sendable {
    typealias InboundOut = ServerOp

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // Save the reader index in case we need to wait for more data
        let savedReaderIndex = buffer.readerIndex

        // Try to read the command line (up to first \r\n)
        guard let line = buffer.readLine() else {
            buffer.moveReaderIndex(to: savedReaderIndex)
            return .needMoreData
        }

        // Parse the command
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let command = parts.first else {
            throw ProtocolError.invalidMessage("Empty protocol line")
        }

        let commandStr = String(command).uppercased()

        switch commandStr {
        case "INFO":
            guard parts.count > 1 else {
                throw ProtocolError.invalidMessage("INFO missing payload")
            }
            let jsonStr = String(parts[1])
            guard let jsonData = jsonStr.data(using: .utf8) else {
                throw ProtocolError.invalidMessage("Invalid INFO JSON encoding")
            }
            let serverInfo = try JSONDecoder().decode(ServerInfo.self, from: jsonData)
            context.fireChannelRead(wrapInboundOut(.info(serverInfo)))

        case "MSG":
            let result = try decodeMsg(line: line, buffer: &buffer, savedIndex: savedReaderIndex)
            switch result {
            case .needMoreData:
                return .needMoreData
            case .decoded(let op):
                context.fireChannelRead(wrapInboundOut(op))
            }

        case "HMSG":
            let result = try decodeHMsg(line: line, buffer: &buffer, savedIndex: savedReaderIndex)
            switch result {
            case .needMoreData:
                return .needMoreData
            case .decoded(let op):
                context.fireChannelRead(wrapInboundOut(op))
            }

        case "PING":
            context.fireChannelRead(wrapInboundOut(.ping))

        case "PONG":
            context.fireChannelRead(wrapInboundOut(.pong))

        case "+OK":
            context.fireChannelRead(wrapInboundOut(.ok))

        case "-ERR":
            let errorMsg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) : "Unknown error"
            context.fireChannelRead(wrapInboundOut(.err(errorMsg)))

        default:
            throw ProtocolError.invalidMessage("Unknown command: \(commandStr)")
        }

        return .continue
    }

    // MARK: - MSG Decoding

    private enum DecodeResult {
        case needMoreData
        case decoded(ServerOp)
    }

    private func decodeMsg(line: String, buffer: inout ByteBuffer, savedIndex: Int) throws -> DecodeResult {
        // MSG <subject> <sid> [reply-to] <#bytes>
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)

        guard parts.count >= 4 else {
            throw ProtocolError.invalidMessage("Invalid MSG format")
        }

        let subject = String(parts[1])
        let sid = String(parts[2])
        let reply: String?
        let payloadSize: Int

        if parts.count == 4 {
            // No reply-to
            reply = nil
            guard let size = Int(parts[3]) else {
                throw ProtocolError.invalidMessage("Invalid MSG payload size")
            }
            payloadSize = size
        } else {
            // Has reply-to
            reply = String(parts[3])
            guard let size = Int(parts[4]) else {
                throw ProtocolError.invalidMessage("Invalid MSG payload size")
            }
            payloadSize = size
        }

        // Check if we have enough data for payload + CRLF
        guard buffer.readableBytes >= payloadSize + 2 else {
            buffer.moveReaderIndex(to: savedIndex)
            return .needMoreData
        }

        // Read payload
        guard let payload = buffer.readSlice(length: payloadSize) else {
            buffer.moveReaderIndex(to: savedIndex)
            return .needMoreData
        }

        // Consume trailing CRLF
        buffer.moveReaderIndex(forwardBy: 2)

        return .decoded(.msg(subject: subject, sid: sid, reply: reply, payload: payload))
    }

    private func decodeHMsg(line: String, buffer: inout ByteBuffer, savedIndex: Int) throws -> DecodeResult {
        // HMSG <subject> <sid> [reply-to] <#header bytes> <#total bytes>
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)

        guard parts.count >= 5 else {
            throw ProtocolError.invalidMessage("Invalid HMSG format")
        }

        let subject = String(parts[1])
        let sid = String(parts[2])
        let reply: String?
        let headerSize: Int
        let totalSize: Int

        if parts.count == 5 {
            // No reply-to
            reply = nil
            guard let hSize = Int(parts[3]), let tSize = Int(parts[4]) else {
                throw ProtocolError.invalidMessage("Invalid HMSG sizes")
            }
            headerSize = hSize
            totalSize = tSize
        } else {
            // Has reply-to
            reply = String(parts[3])
            guard let hSize = Int(parts[4]), let tSize = Int(parts[5]) else {
                throw ProtocolError.invalidMessage("Invalid HMSG sizes")
            }
            headerSize = hSize
            totalSize = tSize
        }

        // Check if we have enough data for total + CRLF
        guard buffer.readableBytes >= totalSize + 2 else {
            buffer.moveReaderIndex(to: savedIndex)
            return .needMoreData
        }

        // Read and parse headers
        guard let headerSlice = buffer.readSlice(length: headerSize) else {
            buffer.moveReaderIndex(to: savedIndex)
            return .needMoreData
        }

        let headers = try parseHeaders(headerSlice)

        // Read payload
        let payloadSize = totalSize - headerSize
        guard let payload = buffer.readSlice(length: payloadSize) else {
            buffer.moveReaderIndex(to: savedIndex)
            return .needMoreData
        }

        // Consume trailing CRLF
        buffer.moveReaderIndex(forwardBy: 2)

        return .decoded(.hmsg(subject: subject, sid: sid, reply: reply, headers: headers, payload: payload))
    }

    // MARK: - Header Parsing

    private func parseHeaders(_ buffer: ByteBuffer) throws -> NatsHeaders {
        guard let headerStr = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
            throw ProtocolError.invalidHeader("Unable to read header bytes as string")
        }

        var headers = NatsHeaders()
        let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)

        guard !lines.isEmpty else {
            return headers
        }

        // First line should be NATS/1.0 [status] [description]
        let versionLine = String(lines[0])
        if versionLine.hasPrefix("NATS/1.0") {
            let versionParts = versionLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if versionParts.count > 1 {
                headers[NatsHeaders.Keys.status] = String(versionParts[1])
            }
            if versionParts.count > 2 {
                headers[NatsHeaders.Keys.description] = String(versionParts[2])
            }
        }

        // Parse remaining header lines
        for line in lines.dropFirst() {
            if line.isEmpty {
                continue
            }

            guard let colonIndex = line.firstIndex(of: ":") else {
                continue
            }

            let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let valueStart = line.index(after: colonIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)

            if !key.isEmpty {
                headers.append(key, value)
            }
        }

        return headers
    }
}

// MARK: - ByteBuffer Extensions

extension ByteBuffer {
    /// Read a line terminated by \r\n
    mutating func readLine() -> String? {
        var index = readerIndex
        let endIndex = readerIndex + readableBytes

        while index < endIndex - 1 {
            if getInteger(at: index, as: UInt8.self) == 0x0D &&  // \r
               getInteger(at: index + 1, as: UInt8.self) == 0x0A {  // \n
                let length = index - readerIndex
                guard let line = readString(length: length) else {
                    return nil
                }
                // Skip the \r\n
                moveReaderIndex(forwardBy: 2)
                return line
            }
            index += 1
        }

        return nil
    }
}
