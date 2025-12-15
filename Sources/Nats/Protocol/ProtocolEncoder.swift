// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import NIOCore

/// Encodes ClientOp into NATS wire protocol
struct ProtocolEncoder: MessageToByteEncoder, Sendable {
    typealias OutboundIn = ClientOp

    func encode(data: ClientOp, out: inout ByteBuffer) throws {
        switch data {
        case .connect(let info):
            try encodeConnect(info, out: &out)

        case .ping:
            out.writeString("PING\r\n")

        case .pong:
            out.writeString("PONG\r\n")

        case .subscribe(let sid, let subject, let queue):
            encodeSubscribe(sid: sid, subject: subject, queue: queue, out: &out)

        case .unsubscribe(let sid, let max):
            encodeUnsubscribe(sid: sid, max: max, out: &out)

        case .publish(let subject, let reply, let headers, let payload):
            encodePublish(subject: subject, reply: reply, headers: headers, payload: payload, out: &out)
        }
    }

    // MARK: - Private Encoding Methods

    private func encodeConnect(_ info: ConnectInfo, out: inout ByteBuffer) throws {
        let encoder = JSONEncoder()
        let json = try encoder.encode(info)
        out.writeString("CONNECT ")
        out.writeBytes(json)
        out.writeString("\r\n")
    }

    private func encodeSubscribe(sid: String, subject: String, queue: String?, out: inout ByteBuffer) {
        out.writeString("SUB ")
        out.writeString(subject)

        if let queue = queue {
            out.writeString(" ")
            out.writeString(queue)
        }

        out.writeString(" ")
        out.writeString(sid)
        out.writeString("\r\n")
    }

    private func encodeUnsubscribe(sid: String, max: Int?, out: inout ByteBuffer) {
        out.writeString("UNSUB ")
        out.writeString(sid)

        if let max = max {
            out.writeString(" ")
            out.writeString(String(max))
        }

        out.writeString("\r\n")
    }

    private func encodePublish(subject: String, reply: String?, headers: NatsHeaders?, payload: ByteBuffer, out: inout ByteBuffer) {
        if let headers = headers, !headers.isEmpty {
            // HPUB with headers
            encodeHPub(subject: subject, reply: reply, headers: headers, payload: payload, out: &out)
        } else {
            // Standard PUB without headers
            encodePub(subject: subject, reply: reply, payload: payload, out: &out)
        }
    }

    private func encodePub(subject: String, reply: String?, payload: ByteBuffer, out: inout ByteBuffer) {
        out.writeString("PUB ")
        out.writeString(subject)

        if let reply = reply {
            out.writeString(" ")
            out.writeString(reply)
        }

        out.writeString(" ")
        out.writeString(String(payload.readableBytes))
        out.writeString("\r\n")
        out.writeImmutableBuffer(payload)
        out.writeString("\r\n")
    }

    private func encodeHPub(subject: String, reply: String?, headers: NatsHeaders, payload: ByteBuffer, out: inout ByteBuffer) {
        // Build headers block
        var headersBuffer = ByteBuffer()
        headersBuffer.writeString("NATS/1.0\r\n")
        for (key, value) in headers {
            headersBuffer.writeString(key)
            headersBuffer.writeString(": ")
            headersBuffer.writeString(value)
            headersBuffer.writeString("\r\n")
        }
        headersBuffer.writeString("\r\n")

        let headerSize = headersBuffer.readableBytes
        let totalSize = headerSize + payload.readableBytes

        out.writeString("HPUB ")
        out.writeString(subject)

        if let reply = reply {
            out.writeString(" ")
            out.writeString(reply)
        }

        out.writeString(" ")
        out.writeString(String(headerSize))
        out.writeString(" ")
        out.writeString(String(totalSize))
        out.writeString("\r\n")
        out.writeBuffer(&headersBuffer)
        out.writeImmutableBuffer(payload)
        out.writeString("\r\n")
    }
}
