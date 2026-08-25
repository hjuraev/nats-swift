// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Errors specific to JetStream operations
public enum JetStreamError: NatsErrorProtocol {
    /// JetStream is not enabled on this server, or this account is not
    /// entitled to use it.
    ///
    /// A verdict about the deployment, not a transient condition: nothing is
    /// subscribed to `$JS.API.>`. Safe to cache. Contrast `notConnected`.
    case notEnabled

    /// The client is not connected, so the JetStream API could not be reached.
    ///
    /// Transient and retryable — it says nothing about whether the server
    /// supports JetStream. Anything caching a JetStream capability check must
    /// never cache this: a reconnect window would otherwise be recorded as a
    /// permanent "no JetStream here".
    case notConnected

    /// The task was cancelled before the operation completed.
    ///
    /// Distinct from `timeout`: no deadline elapsed, so it carries no signal
    /// about server health or latency.
    case cancelled

    /// Transport or protocol failure while reaching the JetStream API.
    ///
    /// Retryability is unknown; the payload carries the underlying description.
    case transport(String)

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

    /// Invalid bucket name
    case invalidBucketName(String)

    /// Invalid key
    case invalidKey(String)

    /// Key not found
    case keyNotFound(String)

    /// Key already exists (CAS conflict)
    case keyExists(key: String, revision: UInt64)

    /// Bucket not found
    case bucketNotFound(String)

    /// History limit exceeded
    case historyExceeded(max: Int)

    /// KV operation failed
    case kvOperationFailed(String)

    public var description: String {
        switch self {
        case .notEnabled:
            return "JetStream is not enabled on this server (or for this account)"
        case .notConnected:
            return "Not connected to a NATS server; JetStream API unreachable"
        case .cancelled:
            return "JetStream operation cancelled"
        case .transport(let reason):
            return "JetStream transport failure: \(reason)"
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
        case .invalidBucketName(let name):
            return "Invalid bucket name: '\(name)'"
        case .invalidKey(let key):
            return "Invalid key: '\(key)'"
        case .keyNotFound(let key):
            return "Key not found: '\(key)'"
        case .keyExists(let key, let revision):
            return "Key already exists: '\(key)' at revision \(revision)"
        case .bucketNotFound(let name):
            return "Bucket not found: '\(name)'"
        case .historyExceeded(let max):
            return "History limit exceeded: max \(max)"
        case .kvOperationFailed(let reason):
            return "KV operation failed: \(reason)"
        }
    }

}

// MARK: - Client Error Mapping

extension JetStreamError {
    /// Translate a client-layer error into the JetStream vocabulary.
    ///
    /// Every error that was not already a `JetStreamError` used to collapse into
    /// `.timeout`, which made four unrelated situations indistinguishable: a
    /// server with JetStream disabled, a genuinely slow request, a client that is
    /// not connected, and a cancelled task. Anything that gates behaviour on
    /// JetStream availability needs those apart — a reconnect window must not be
    /// recorded as "this deployment has no JetStream".
    ///
    /// - Parameters:
    ///   - error: The error thrown by the client layer.
    ///   - operation: Operation name used when reporting a timeout.
    ///   - timeout: Deadline used when reporting a timeout.
    public static func mapping(
        _ error: any Error,
        operation: String,
        timeout: Duration
    ) -> JetStreamError {
        switch error {
        case let jetStreamError as JetStreamError:
            return jetStreamError

        case is CancellationError:
            return .cancelled

        case let protocolError as ProtocolError:
            switch protocolError {
            case .noResponders:
                // Nothing is subscribed to `$JS.API.>`. `NatsClient` turns the
                // server's 503 into this before the reply reaches the JetStream
                // layer, so it is the ONLY signal that the server is not serving
                // JetStream at all — the `isNoResponders` header check in
                // `JetStreamContext` never sees that message.
                return .notEnabled
            case .staleConnection:
                return .notConnected
            default:
                return .transport(protocolError.description)
            }

        case let connectionError as ConnectionError:
            switch connectionError {
            case .closed, .draining, .noServersAvailable, .maxReconnectsExceeded:
                return .notConnected
            case .timeout, .writeTimedOut, .backpressured:
                // All three are deadline expiries. `backpressured` (nothing
                // written, safe to retry) and `writeTimedOut` (possibly partly
                // written, outcome unknown) differ in retry semantics, and that
                // distinction is flattened here — callers that need it should
                // inspect the client error before it reaches this mapping.
                return .timeout(operation: operation, after: timeout)
            default:
                return .transport(connectionError.description)
            }

        case let natsError as NatsError:
            switch natsError {
            case .timeout(let timedOutOperation, let after):
                return .timeout(operation: timedOutOperation, after: after)
            case .cancelled:
                return .cancelled
            case .jetStream(let jetStreamError):
                return jetStreamError
            case .connection(let connectionError):
                return mapping(connectionError, operation: operation, timeout: timeout)
            case .protocol(let protocolError):
                return mapping(protocolError, operation: operation, timeout: timeout)
            }

        default:
            return .transport(String(describing: error))
        }
    }

    /// Whether this error is a verdict about JetStream availability rather than
    /// a transient failure.
    ///
    /// `true` only for `notEnabled` — the one case that means "this server or
    /// account does not serve JetStream". Everything else (`notConnected`,
    /// `timeout`, `cancelled`, `transport`) may succeed on a later attempt, so a
    /// capability check must retry rather than conclude.
    public var isJetStreamUnavailableVerdict: Bool {
        if case .notEnabled = self { return true }
        return false
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
