// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import NIOCore

/// Operations received from the server
enum ServerOp: Sendable {
    /// INFO - Server information, sent on connect
    case info(ServerInfo)

    /// MSG - Message without headers
    /// - subject: Subject the message was received on
    /// - sid: Subscription ID
    /// - reply: Optional reply subject
    /// - payload: Message payload
    case msg(subject: String, sid: String, reply: String?, payload: ByteBuffer)

    /// HMSG - Message with headers
    /// - subject: Subject the message was received on
    /// - sid: Subscription ID
    /// - reply: Optional reply subject
    /// - headers: NATS headers
    /// - payload: Message payload
    case hmsg(subject: String, sid: String, reply: String?, headers: NatsHeaders, payload: ByteBuffer)

    /// PING - Server ping, requires PONG response
    case ping

    /// PONG - Server response to client PING
    case pong

    /// +OK - Acknowledgement (verbose mode)
    case ok

    /// -ERR - Protocol error from server
    case err(String)
}

/// Header in a received message before the payload
struct MessageHeader: Sendable {
    let subject: String
    let sid: String
    let reply: String?
    let payloadLength: Int
    let headerLength: Int?  // Only for HMSG
}
