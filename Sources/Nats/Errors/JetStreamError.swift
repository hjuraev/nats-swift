// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Errors specific to JetStream operations
public enum JetStreamError: NatsErrorProtocol {
    /// JetStream is not enabled on this server
    case notEnabled

    /// Stream not found
    case streamNotFound(String)

    /// Consumer not found
    case consumerNotFound(stream: String, consumer: String)

    /// Message not found in stream
    case messageNotFound(stream: String, sequence: UInt64)

    /// Duplicate message detected
    case duplicateMessage(stream: String, sequence: UInt64)

    /// Invalid acknowledgement
    case invalidAck(String)

    /// JetStream operation timeout
    case timeout(operation: String, after: Duration)

    /// JetStream API error from server
    case apiError(code: Int, errorCode: Int, description: String)

    /// Invalid stream configuration
    case invalidStreamConfig(String)

    /// Invalid consumer configuration
    case invalidConsumerConfig(String)

    /// Stream name is required
    case streamNameRequired

    /// Consumer name is required
    case consumerNameRequired

    /// Invalid stream name
    case invalidStreamName(String)

    /// Invalid consumer name
    case invalidConsumerName(String)

    /// Message acknowledgement failed
    case ackFailed(String)

    /// Pull request failed
    case pullFailed(String)

    /// Publish failed
    case publishFailed(String)

    public var description: String {
        switch self {
        case .notEnabled:
            return "JetStream is not enabled on this server"
        case .streamNotFound(let name):
            return "Stream not found: '\(name)'"
        case .consumerNotFound(let stream, let consumer):
            return "Consumer '\(consumer)' not found in stream '\(stream)'"
        case .messageNotFound(let stream, let sequence):
            return "Message not found: stream '\(stream)', sequence \(sequence)"
        case .duplicateMessage(let stream, let sequence):
            return "Duplicate message: stream '\(stream)', sequence \(sequence)"
        case .invalidAck(let reason):
            return "Invalid acknowledgement: \(reason)"
        case .timeout(let operation, let duration):
            return "JetStream timeout: \(operation) after \(duration)"
        case .apiError(let code, let errorCode, let description):
            return "JetStream API error [\(code)/\(errorCode)]: \(description)"
        case .invalidStreamConfig(let reason):
            return "Invalid stream configuration: \(reason)"
        case .invalidConsumerConfig(let reason):
            return "Invalid consumer configuration: \(reason)"
        case .streamNameRequired:
            return "Stream name is required"
        case .consumerNameRequired:
            return "Consumer name is required"
        case .invalidStreamName(let name):
            return "Invalid stream name: '\(name)'"
        case .invalidConsumerName(let name):
            return "Invalid consumer name: '\(name)'"
        case .ackFailed(let reason):
            return "Message acknowledgement failed: \(reason)"
        case .pullFailed(let reason):
            return "Pull request failed: \(reason)"
        case .publishFailed(let reason):
            return "Publish failed: \(reason)"
        }
    }

}

extension JetStreamError: LocalizedError {
    /// LocalizedError conformance for proper error logging
    public var errorDescription: String? {
        description
    }
}

extension JetStreamError: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(description)
    }

    public static func == (lhs: JetStreamError, rhs: JetStreamError) -> Bool {
        lhs.description == rhs.description
    }
}
