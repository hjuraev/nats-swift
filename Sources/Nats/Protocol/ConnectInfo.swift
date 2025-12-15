// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Information sent to server during connection handshake
struct ConnectInfo: Codable, Sendable {
    /// Whether to operate in verbose mode (receive +OK for each command)
    let verbose: Bool

    /// Whether to pedantic mode (strict protocol checking)
    let pedantic: Bool

    /// TLS required flag
    let tlsRequired: Bool

    /// Authentication token (optional)
    let authToken: String?

    /// Username (optional)
    let user: String?

    /// Password (optional)
    let pass: String?

    /// Client name (optional)
    let name: String?

    /// Language implementation
    let lang: String

    /// Client version
    let version: String

    /// Protocol version
    let `protocol`: Int

    /// Whether client echoes its own messages
    let echo: Bool

    /// Whether client supports headers
    let headers: Bool

    /// Whether client wants no-responders messages
    let noResponders: Bool

    /// JWT token for authentication (optional)
    let jwt: String?

    /// NKey public key (optional)
    let nkey: String?

    /// Signature for NKey authentication (optional)
    let sig: String?

    enum CodingKeys: String, CodingKey {
        case verbose
        case pedantic
        case tlsRequired = "tls_required"
        case authToken = "auth_token"
        case user
        case pass
        case name
        case lang
        case version
        case `protocol` = "protocol"
        case echo
        case headers
        case noResponders = "no_responders"
        case jwt
        case nkey
        case sig
    }

    init(
        verbose: Bool = false,
        pedantic: Bool = false,
        tlsRequired: Bool = false,
        authToken: String? = nil,
        user: String? = nil,
        pass: String? = nil,
        name: String? = nil,
        lang: String = "swift",
        version: String = "2.0.0",
        protocol: Int = 1,  // Protocol 1 required for headers/JetStream
        echo: Bool = true,
        headers: Bool = true,
        noResponders: Bool = true,
        jwt: String? = nil,
        nkey: String? = nil,
        sig: String? = nil
    ) {
        self.verbose = verbose
        self.pedantic = pedantic
        self.tlsRequired = tlsRequired
        self.authToken = authToken
        self.user = user
        self.pass = pass
        self.name = name
        self.lang = lang
        self.version = version
        self.protocol = `protocol`
        self.echo = echo
        self.headers = headers
        self.noResponders = noResponders
        self.jwt = jwt
        self.nkey = nkey
        self.sig = sig
    }
}
