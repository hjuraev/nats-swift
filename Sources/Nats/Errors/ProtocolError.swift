// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Errors related to NATS protocol violations and message handling
public enum ProtocolError: NatsErrorProtocol, Hashable {
    /// Subject is invalid (empty, contains invalid characters, or too long)
    case invalidSubject(String)

    /// Header name or value is invalid
    case invalidHeader(String)

    /// Payload exceeds the server's maximum allowed size
    case payloadTooLarge(size: Int, max: Int)

    /// Connection became stale (missed too many pings)
    case staleConnection

    /// Permission denied for the operation
    case permissionViolation(operation: String, subject: String)

    /// Server returned a protocol error
    case serverError(String)

    /// Invalid protocol message received
    case invalidMessage(String)

    /// Subscription not found
    case subscriptionNotFound(sid: String)

    /// Request has no responders
    case noResponders(subject: String)

    /// Invalid queue group name
    case invalidQueueGroup(String)

    public var description: String {
        switch self {
        case .invalidSubject(let subject):
            return "Invalid subject: '\(subject)'"
        case .invalidHeader(let reason):
            return "Invalid header: \(reason)"
        case .payloadTooLarge(let size, let max):
            return "Payload too large: \(size) bytes exceeds maximum of \(max) bytes"
        case .staleConnection:
            return "Connection is stale (missed pings)"
        case .permissionViolation(let operation, let subject):
            return "Permission denied: \(operation) on '\(subject)'"
        case .serverError(let message):
            return "Server error: \(message)"
        case .invalidMessage(let reason):
            return "Invalid protocol message: \(reason)"
        case .subscriptionNotFound(let sid):
            return "Subscription not found: \(sid)"
        case .noResponders(let subject):
            return "No responders available for subject: '\(subject)'"
        case .invalidQueueGroup(let name):
            return "Invalid queue group name: '\(name)'"
        }
    }

}

extension ProtocolError: LocalizedError {
    /// LocalizedError conformance for proper error logging
    public var errorDescription: String? {
        description
    }
}
