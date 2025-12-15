// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Connection states for the NATS client
public enum ConnectionState: Sendable, Equatable, CustomStringConvertible {
    /// Client is disconnected and not attempting to connect
    case disconnected

    /// Client is attempting to establish a connection
    case connecting

    /// Client is performing TLS handshake
    case tlsHandshake

    /// Client is connected and ready
    case connected(ServerInfo)

    /// Client is attempting to reconnect after a connection loss
    case reconnecting(attempt: Int)

    /// Client is draining (finishing pending operations before closing)
    case draining

    /// Client is permanently closed
    case closed

    public var description: String {
        switch self {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .tlsHandshake:
            return "tls_handshake"
        case .connected:
            return "connected"
        case .reconnecting(let attempt):
            return "reconnecting(attempt: \(attempt))"
        case .draining:
            return "draining"
        case .closed:
            return "closed"
        }
    }

    public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.tlsHandshake, .tlsHandshake),
             (.draining, .draining),
             (.closed, .closed):
            return true
        case (.connected(let a), .connected(let b)):
            return a == b
        case (.reconnecting(let a), .reconnecting(let b)):
            return a == b
        default:
            return false
        }
    }

    /// Whether the client is connected or reconnecting (can still send messages)
    public var isActive: Bool {
        switch self {
        case .connected, .draining:
            return true
        default:
            return false
        }
    }

    /// Whether the client can accept new operations
    public var canAcceptOperations: Bool {
        switch self {
        case .connected:
            return true
        default:
            return false
        }
    }

    /// Server info if connected
    public var serverInfo: ServerInfo? {
        if case .connected(let info) = self {
            return info
        }
        return nil
    }
}

/// Events that can trigger state transitions
enum ConnectionEvent: Sendable {
    case connect
    case tlsRequired
    case tlsComplete
    case connected(ServerInfo)
    case disconnected(Error?)
    case reconnecting(attempt: Int)
    case drain
    case close
}

/// State machine for connection lifecycle
struct ConnectionStateMachine: Sendable {
    private(set) var state: ConnectionState = .disconnected

    /// Attempt to transition to a new state
    mutating func transition(on event: ConnectionEvent) -> ConnectionState? {
        let newState: ConnectionState?

        switch (state, event) {
        // From disconnected
        case (.disconnected, .connect):
            newState = .connecting

        case (.disconnected, .close):
            newState = .closed

        // From connecting
        case (.connecting, .tlsRequired):
            newState = .tlsHandshake

        case (.connecting, .connected(let info)):
            newState = .connected(info)

        case (.connecting, .disconnected):
            newState = .disconnected

        case (.connecting, .close):
            newState = .closed

        // From TLS handshake
        case (.tlsHandshake, .tlsComplete):
            newState = .connecting

        case (.tlsHandshake, .disconnected):
            newState = .disconnected

        case (.tlsHandshake, .close):
            newState = .closed

        // From connected
        case (.connected, .disconnected):
            newState = .disconnected

        case (.connected, .reconnecting(let attempt)):
            newState = .reconnecting(attempt: attempt)

        case (.connected, .drain):
            newState = .draining

        case (.connected, .close):
            newState = .closed

        // From reconnecting
        case (.reconnecting, .connected(let info)):
            newState = .connected(info)

        case (.reconnecting, .reconnecting(let attempt)):
            newState = .reconnecting(attempt: attempt)

        case (.reconnecting, .disconnected):
            newState = .disconnected

        case (.reconnecting, .close):
            newState = .closed

        // From draining
        case (.draining, .disconnected):
            newState = .disconnected

        case (.draining, .close):
            newState = .closed

        // From closed - no transitions allowed
        case (.closed, _):
            newState = nil

        default:
            newState = nil
        }

        if let newState = newState {
            state = newState
        }

        return newState
    }

    /// Force set state (for error recovery)
    mutating func forceState(_ newState: ConnectionState) {
        state = newState
    }
}
