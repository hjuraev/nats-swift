// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Server information received during connection handshake
public struct ServerInfo: Codable, Sendable, Hashable {
    /// Server unique identifier
    public let serverId: String

    /// Server name
    public let serverName: String

    /// Server version string
    public let version: String

    /// Protocol version supported
    public let proto: Int

    /// Git commit hash (optional)
    public let gitCommit: String?

    /// Go version used to build the server (optional)
    public let go: String?

    /// Server host
    public let host: String

    /// Server port
    public let port: Int

    /// Whether server supports headers
    public let headers: Bool

    /// Maximum payload size allowed
    public let maxPayload: Int

    /// Server's JetStream domain (optional)
    public let jetstream: Bool?

    /// Client ID assigned by server (optional)
    public let clientId: UInt64?

    /// Client IP as seen by server (optional)
    public let clientIp: String?

    /// Cluster name (optional)
    public let cluster: String?

    /// Known server URLs for cluster (optional)
    public let connectUrls: [String]?

    /// Whether TLS is required
    public let tlsRequired: Bool?

    /// Whether TLS is available
    public let tlsAvailable: Bool?

    /// Whether authentication is required
    public let authRequired: Bool?

    /// Nonce for authentication (optional)
    public let nonce: String?

    /// Whether server supports lame duck mode
    public let lameDuckMode: Bool?

    enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case serverName = "server_name"
        case version
        case proto
        case gitCommit = "git_commit"
        case go
        case host
        case port
        case headers
        case maxPayload = "max_payload"
        case jetstream
        case clientId = "client_id"
        case clientIp = "client_ip"
        case cluster
        case connectUrls = "connect_urls"
        case tlsRequired = "tls_required"
        case tlsAvailable = "tls_available"
        case authRequired = "auth_required"
        case nonce
        case lameDuckMode = "ldm"
    }

    public init(
        serverId: String,
        serverName: String,
        version: String,
        proto: Int,
        gitCommit: String? = nil,
        go: String? = nil,
        host: String,
        port: Int,
        headers: Bool,
        maxPayload: Int,
        jetstream: Bool? = nil,
        clientId: UInt64? = nil,
        clientIp: String? = nil,
        cluster: String? = nil,
        connectUrls: [String]? = nil,
        tlsRequired: Bool? = nil,
        tlsAvailable: Bool? = nil,
        authRequired: Bool? = nil,
        nonce: String? = nil,
        lameDuckMode: Bool? = nil
    ) {
        self.serverId = serverId
        self.serverName = serverName
        self.version = version
        self.proto = proto
        self.gitCommit = gitCommit
        self.go = go
        self.host = host
        self.port = port
        self.headers = headers
        self.maxPayload = maxPayload
        self.jetstream = jetstream
        self.clientId = clientId
        self.clientIp = clientIp
        self.cluster = cluster
        self.connectUrls = connectUrls
        self.tlsRequired = tlsRequired
        self.tlsAvailable = tlsAvailable
        self.authRequired = authRequired
        self.nonce = nonce
        self.lameDuckMode = lameDuckMode
    }
}
