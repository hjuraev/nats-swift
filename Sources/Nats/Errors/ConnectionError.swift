// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Errors related to connection lifecycle and network operations
public enum ConnectionError: NatsErrorProtocol, Hashable {
    /// The provided URL is invalid
    case invalidURL(String)

    /// Connection was refused by the server
    case connectionRefused(host: String, port: Int)

    /// TLS handshake failed
    case tlsHandshakeFailed(reason: String)

    /// Authentication failed
    case authenticationFailed(reason: String)

    /// Maximum reconnection attempts exceeded
    case maxReconnectsExceeded(attempts: Int)

    /// Server is shutting down
    case serverShuttingDown

    /// Connection timeout
    case timeout(after: Duration)

    /// Connection is closed
    case closed

    /// The connection's outbound buffer stayed full for longer than
    /// `writeBackpressureTimeout`, so the write was refused rather than queued.
    ///
    /// Distinct from `timeout` on purpose: nothing was written, so this is safe
    /// to retry on the same connection once it drains. A write that has already
    /// been handed to the channel cannot make that promise.
    case backpressured(after: Duration)

    /// A write did not reach the socket within `writeTimeout`, so the frame was
    /// abandoned and the connection torn down.
    ///
    /// Unlike `backpressured`, this frame may have been *partially* written.
    /// Bytes already handed to the channel cannot be recalled, and a stream
    /// carrying half a frame cannot be reused — so the connection goes with it.
    /// Treat the operation's outcome as unknown, not as "did not happen".
    case writeTimedOut(after: Duration)

    /// Connection is draining
    case draining

    /// DNS resolution failed
    case dnsResolutionFailed(host: String)

    /// No servers available to connect
    case noServersAvailable

    /// Server requires TLS but client is not configured for it
    case tlsRequired

    /// TLS configuration failed
    case tlsConfigurationFailed(String)

    /// IO error occurred
    case io(String)

    public var description: String {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .connectionRefused(let host, let port):
            return "Connection refused to \(host):\(port)"
        case .tlsHandshakeFailed(let reason):
            return "TLS handshake failed: \(reason)"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .maxReconnectsExceeded(let attempts):
            return "Maximum reconnection attempts (\(attempts)) exceeded"
        case .serverShuttingDown:
            return "Server is shutting down"
        case .timeout(let duration):
            return "Connection timeout after \(duration)"
        case .closed:
            return "Connection is closed"
        case .backpressured(let duration):
            return "Connection outbound buffer stayed full for \(duration); write refused, nothing was sent"
        case .writeTimedOut(let duration):
            return "Write did not reach the socket within \(duration); frame abandoned and connection closed"
        case .draining:
            return "Connection is draining"
        case .dnsResolutionFailed(let host):
            return "DNS resolution failed for \(host)"
        case .noServersAvailable:
            return "No servers available to connect"
        case .tlsRequired:
            return "Server requires TLS but client is not configured for it"
        case .tlsConfigurationFailed(let reason):
            return "TLS configuration failed: \(reason)"
        case .io(let message):
            return "IO error: \(message)"
        }
    }

}

extension ConnectionError: LocalizedError {
    /// LocalizedError conformance for proper error logging
    public var errorDescription: String? {
        description
    }
}
