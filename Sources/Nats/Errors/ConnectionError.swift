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
