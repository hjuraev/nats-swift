// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

/// Base protocol for all NATS errors, enabling typed throws
public protocol NatsErrorProtocol: Error, Sendable, CustomStringConvertible {}

/// General NATS error that wraps specific error domains
public enum NatsError: Error, Sendable {
    case connection(ConnectionError)
    case `protocol`(ProtocolError)
    case jetStream(JetStreamError)
    case timeout(operation: String, after: Duration)
    case cancelled
}

extension NatsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .connection(let error):
            return "Connection error: \(error)"
        case .protocol(let error):
            return "Protocol error: \(error)"
        case .jetStream(let error):
            return "JetStream error: \(error)"
        case .timeout(let operation, let duration):
            return "Timeout: \(operation) after \(duration)"
        case .cancelled:
            return "Operation cancelled"
        }
    }
}
