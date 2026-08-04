// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import Logging
import NIOCore

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

    /// Maximum time for a single connection attempt: the TCP connect plus the
    /// NATS handshake, measured as one budget rather than one deadline each.
    /// Applies to reconnect attempts as well as the initial connect.
    public var connectTimeout: Duration

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

    /// Outbound buffer thresholds at which the connection reports itself
    /// unwritable and writable again.
    ///
    /// The client checks `channel.isWritable` before every frame, so these
    /// bounds are what stop a peer that stops reading from turning into
    /// unbounded memory growth on this side.
    public var writeBufferWaterMark: WriteBufferWaterMark

    /// How long a write waits for a saturated connection to drain before being
    /// refused with `ConnectionError.backpressured`.
    ///
    /// Refusing is safe: nothing has been queued, so the caller can retry. This
    /// is deliberately *not* a deadline on a write already in flight — that one
    /// cannot be undone once the bytes are handed to the channel.
    public var writeBackpressureTimeout: Duration

    /// How long a single frame may take to reach the socket before it is
    /// abandoned and **the connection is closed**.
    ///
    /// Closing is not optional. Bytes handed to the channel cannot be recalled,
    /// so a frame abandoned midway leaves the stream desynchronised — every
    /// later operation on that connection would land at a frame boundary the
    /// server no longer agrees with. Bounding a write therefore costs the
    /// connection; reconnection (when enabled) rebuilds it.
    ///
    /// The default is generous on purpose. NATS caps a single frame at the
    /// server's `max_payload` (commonly 1 MiB), so a frame that cannot reach
    /// the socket in 30s indicates a dead peer rather than a slow one. Raise it
    /// if you run unusually large payloads over unusually slow links.
    public var writeTimeout: Duration

    /// Event-loop group to run this client's connection on.
    ///
    /// `nil` (the default) means the client creates and owns a single-threaded
    /// group of its own. That is fine for one client, but N clients in a process
    /// then cost N groups and N threads — supply a shared group here to make
    /// them cost N channels instead.
    ///
    /// **Ownership:** a group supplied here is never shut down by `close()`;
    /// the caller keeps that responsibility. Only a group the client created
    /// for itself is torn down with the client.
    public var eventLoopGroup: (any EventLoopGroup)?

    public init(
        servers: [URL] = [URL(string: "nats://localhost:4222")!],
        name: String? = nil,
        reconnect: ReconnectPolicy = .init(),
        tls: TLSConfig = .init(),
        auth: AuthConfig = .none,
        pingInterval: Duration = .seconds(120),
        maxPingsOut: Int = 2,
        connectTimeout: Duration = .seconds(5),
        requestTimeout: Duration = .seconds(5),
        drainTimeout: Duration = .seconds(30),
        echo: Bool = true,
        verbose: Bool = false,
        pedantic: Bool = false,
        maxPayload: Int = 0,
        logger: Logger = Logger(label: "nats.client"),
        inboxPrefix: String = "_INBOX",
        writeBufferWaterMark: WriteBufferWaterMark = WriteBufferWaterMark(low: 32 * 1024, high: 64 * 1024),
        writeBackpressureTimeout: Duration = .seconds(5),
        writeTimeout: Duration = .seconds(30),
        eventLoopGroup: (any EventLoopGroup)? = nil
    ) {
        self.servers = servers
        self.name = name
        self.reconnect = reconnect
        self.tls = tls
        self.auth = auth
        self.pingInterval = pingInterval
        self.maxPingsOut = maxPingsOut
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.drainTimeout = drainTimeout
        self.echo = echo
        self.verbose = verbose
        self.pedantic = pedantic
        self.maxPayload = maxPayload
        self.logger = logger
        self.inboxPrefix = inboxPrefix
        self.writeBufferWaterMark = writeBufferWaterMark
        self.writeBackpressureTimeout = writeBackpressureTimeout
        self.writeTimeout = writeTimeout
        self.eventLoopGroup = eventLoopGroup
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

        // Store URL without credentials
        servers = [url.strippingCredentials()]
    }

    /// Parse multiple URL strings
    public mutating func urls(_ urlStrings: [String]) throws {
        var parsedURLs: [URL] = []
        var authExtracted = false

        for urlString in urlStrings {
            guard let url = URL(string: urlString) else {
                throw ConnectionError.invalidURL(urlString)
            }

            // Extract auth from first URL that has credentials
            if !authExtracted, let user = url.user {
                if let password = url.password {
                    auth = .userPass(user: user, password: password)
                } else {
                    auth = .token(user)
                }
                authExtracted = true
            }

            // Check for TLS scheme
            if url.scheme == "tls" || url.scheme == "nats+tls" || url.scheme == "wss" {
                tls.enabled = true
            }

            // Store URL without credentials
            parsedURLs.append(url.strippingCredentials())
        }
        servers = parsedURLs
    }
}

// MARK: - URL Credential Sanitization

extension URL {
    /// Returns a copy of the URL with user credentials removed
    func strippingCredentials() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }

        // Only process if there are credentials to strip
        guard components.user != nil || components.password != nil else {
            return self
        }

        components.user = nil
        components.password = nil

        return components.url ?? self
    }

    /// Returns a string representation of the URL safe for logging (no credentials)
    public var sanitizedDescription: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self.absoluteString
        }

        // Only process if there are credentials to strip
        guard components.user != nil || components.password != nil else {
            return self.absoluteString
        }

        components.user = nil
        components.password = nil

        return components.string ?? self.absoluteString
    }
}
