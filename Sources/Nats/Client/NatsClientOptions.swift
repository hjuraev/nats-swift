// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import Logging

/// Configuration options for NatsClient
public struct NatsClientOptions: Sendable {
    /// List of NATS server URLs to connect to
    public var servers: [URL]

    /// Client name sent to server
    public var name: String?

    /// Reconnection policy
    public var reconnect: ReconnectPolicy

    /// TLS configuration
    public var tls: TLSConfig

    /// Authentication configuration
    public var auth: AuthConfig

    /// Interval between PING messages
    public var pingInterval: Duration

    /// Maximum outstanding PINGs before connection is considered stale
    public var maxPingsOut: Int

    /// Default timeout for request-reply operations
    public var requestTimeout: Duration

    /// Timeout for draining subscriptions on close
    public var drainTimeout: Duration

    /// Whether to echo messages back to the sender
    public var echo: Bool

    /// Whether to use verbose mode (receive +OK for each command)
    public var verbose: Bool

    /// Whether to use pedantic mode (strict protocol checking)
    public var pedantic: Bool

    /// Maximum payload size (0 = use server default)
    public var maxPayload: Int

    /// Logger for the client
    public var logger: Logger

    /// Custom inbox prefix
    public var inboxPrefix: String

    public init(
        servers: [URL] = [URL(string: "nats://localhost:4222")!],
        name: String? = nil,
        reconnect: ReconnectPolicy = .init(),
        tls: TLSConfig = .init(),
        auth: AuthConfig = .none,
        pingInterval: Duration = .seconds(120),
        maxPingsOut: Int = 2,
        requestTimeout: Duration = .seconds(5),
        drainTimeout: Duration = .seconds(30),
        echo: Bool = true,
        verbose: Bool = false,
        pedantic: Bool = false,
        maxPayload: Int = 0,
        logger: Logger = Logger(label: "nats.client"),
        inboxPrefix: String = "_INBOX"
    ) {
        self.servers = servers
        self.name = name
        self.reconnect = reconnect
        self.tls = tls
        self.auth = auth
        self.pingInterval = pingInterval
        self.maxPingsOut = maxPingsOut
        self.requestTimeout = requestTimeout
        self.drainTimeout = drainTimeout
        self.echo = echo
        self.verbose = verbose
        self.pedantic = pedantic
        self.maxPayload = maxPayload
        self.logger = logger
        self.inboxPrefix = inboxPrefix
    }
}

// MARK: - Authentication Configuration

/// Authentication methods for NATS connections
public enum AuthConfig: Sendable {
    /// No authentication
    case none

    /// Token authentication
    case token(String)

    /// Username and password authentication
    case userPass(user: String, password: String)

    /// NKey seed authentication (Ed25519)
    case nkey(seed: String)

    /// JWT credentials file authentication
    case credentials(URL)

    /// JWT with NKey seed
    case jwt(jwt: String, nkeySeed: String)
}

// MARK: - Builder Pattern

extension NatsClientOptions {
    /// Create options with a builder closure
    public static func build(_ configure: (inout NatsClientOptions) -> Void) -> NatsClientOptions {
        var options = NatsClientOptions()
        configure(&options)
        return options
    }
}

// MARK: - URL Parsing

extension NatsClientOptions {
    /// Parse a single URL string
    public mutating func url(_ urlString: String) throws {
        guard let url = URL(string: urlString) else {
            throw ConnectionError.invalidURL(urlString)
        }
        servers = [url]

        // Extract auth from URL if present
        if let user = url.user {
            if let password = url.password {
                auth = .userPass(user: user, password: password)
            } else {
                auth = .token(user)
            }
        }

        // Check for TLS scheme
        if url.scheme == "tls" || url.scheme == "nats+tls" || url.scheme == "wss" {
            tls.enabled = true
        }
    }

    /// Parse multiple URL strings
    public mutating func urls(_ urlStrings: [String]) throws {
        var parsedURLs: [URL] = []
        for urlString in urlStrings {
            guard let url = URL(string: urlString) else {
                throw ConnectionError.invalidURL(urlString)
            }
            parsedURLs.append(url)
        }
        servers = parsedURLs
    }
}
