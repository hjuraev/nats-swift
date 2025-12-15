// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import NIOCore

/// Operations that the client can send to the server
enum ClientOp: Sendable {
    /// CONNECT - Initial connection handshake with server info
    case connect(ConnectInfo)

    /// PING - Keep-alive ping to server
    case ping

    /// PONG - Response to server's PING
    case pong

    /// SUB - Subscribe to a subject
    /// - sid: Subscription ID
    /// - subject: Subject to subscribe to
    /// - queue: Optional queue group for load balancing
    case subscribe(sid: String, subject: String, queue: String?)

    /// UNSUB - Unsubscribe from a subscription
    /// - sid: Subscription ID
    /// - max: Optional max messages to receive before auto-unsubscribe
    case unsubscribe(sid: String, max: Int?)

    /// PUB/HPUB - Publish a message
    /// - subject: Subject to publish to
    /// - reply: Optional reply subject for request-reply pattern
    /// - headers: Optional NATS headers
    /// - payload: Message payload
    case publish(subject: String, reply: String?, headers: NatsHeaders?, payload: ByteBuffer)
}

/// NATS protocol constants
enum NatsProtocolConstants {
    static let crlf: [UInt8] = [0x0D, 0x0A]  // \r\n
    static let space: UInt8 = 0x20           // " "
    static let tab: UInt8 = 0x09             // \t

    // Protocol commands
    static let connect = "CONNECT"
    static let pub = "PUB"
    static let hpub = "HPUB"
    static let sub = "SUB"
    static let unsub = "UNSUB"
    static let ping = "PING"
    static let pong = "PONG"

    // Server responses
    static let info = "INFO"
    static let msg = "MSG"
    static let hmsg = "HMSG"
    static let ok = "+OK"
    static let err = "-ERR"

    // Header version
    static let headerVersion = "NATS/1.0"
}
