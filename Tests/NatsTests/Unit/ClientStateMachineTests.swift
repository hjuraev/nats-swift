// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Nats

@Suite("ConnectionState Tests")
struct ConnectionStateTests {

    // MARK: - Test Helpers

    static func makeServerInfo(
        serverId: String = "test-server-id",
        serverName: String = "test-server"
    ) -> ServerInfo {
        ServerInfo(
            serverId: serverId,
            serverName: serverName,
            version: "2.10.0",
            proto: 1,
            host: "localhost",
            port: 4222,
            headers: true,
            maxPayload: 1048576
        )
    }

    // MARK: - State Description Tests

    @Test("Disconnected state description")
    func disconnectedDescription() {
        let state = ConnectionState.disconnected
        #expect(state.description == "disconnected")
    }

    @Test("Connecting state description")
    func connectingDescription() {
        let state = ConnectionState.connecting
        #expect(state.description == "connecting")
    }

    @Test("TLS handshake state description")
    func tlsHandshakeDescription() {
        let state = ConnectionState.tlsHandshake
        #expect(state.description == "tls_handshake")
    }

    @Test("Connected state description")
    func connectedDescription() {
        let state = ConnectionState.connected(Self.makeServerInfo())
        #expect(state.description == "connected")
    }

    @Test("Reconnecting state description")
    func reconnectingDescription() {
        let state = ConnectionState.reconnecting(attempt: 5)
        #expect(state.description == "reconnecting(attempt: 5)")
    }

    @Test("Draining state description")
    func drainingDescription() {
        let state = ConnectionState.draining
        #expect(state.description == "draining")
    }

    @Test("Closed state description")
    func closedDescription() {
        let state = ConnectionState.closed
        #expect(state.description == "closed")
    }

    // MARK: - State Equality Tests

    @Test("Same simple states are equal")
    func simpleStatesEqual() {
        #expect(ConnectionState.disconnected == ConnectionState.disconnected)
        #expect(ConnectionState.connecting == ConnectionState.connecting)
        #expect(ConnectionState.tlsHandshake == ConnectionState.tlsHandshake)
        #expect(ConnectionState.draining == ConnectionState.draining)
        #expect(ConnectionState.closed == ConnectionState.closed)
    }

    @Test("Different simple states are not equal")
    func differentSimpleStatesNotEqual() {
        #expect(ConnectionState.disconnected != ConnectionState.connecting)
        #expect(ConnectionState.connecting != ConnectionState.tlsHandshake)
        #expect(ConnectionState.draining != ConnectionState.closed)
    }

    @Test("Connected states with same ServerInfo are equal")
    func connectedStatesEqual() {
        let info = Self.makeServerInfo()
        let state1 = ConnectionState.connected(info)
        let state2 = ConnectionState.connected(info)
        #expect(state1 == state2)
    }

    @Test("Connected states with different ServerInfo are not equal")
    func connectedStatesDifferentInfo() {
        let info1 = Self.makeServerInfo(serverId: "server-1")
        let info2 = Self.makeServerInfo(serverId: "server-2")
        let state1 = ConnectionState.connected(info1)
        let state2 = ConnectionState.connected(info2)
        #expect(state1 != state2)
    }

    @Test("Reconnecting states with same attempt are equal")
    func reconnectingStatesEqual() {
        let state1 = ConnectionState.reconnecting(attempt: 3)
        let state2 = ConnectionState.reconnecting(attempt: 3)
        #expect(state1 == state2)
    }

    @Test("Reconnecting states with different attempts are not equal")
    func reconnectingStatesDifferentAttempts() {
        let state1 = ConnectionState.reconnecting(attempt: 1)
        let state2 = ConnectionState.reconnecting(attempt: 2)
        #expect(state1 != state2)
    }

    @Test("Connected and disconnected are not equal")
    func connectedVsDisconnected() {
        let connected = ConnectionState.connected(Self.makeServerInfo())
        let disconnected = ConnectionState.disconnected
        #expect(connected != disconnected)
    }

    // MARK: - isActive Property Tests

    @Test("isActive returns true for connected")
    func isActiveConnected() {
        let state = ConnectionState.connected(Self.makeServerInfo())
        #expect(state.isActive == true)
    }

    @Test("isActive returns true for draining")
    func isActiveDraining() {
        let state = ConnectionState.draining
        #expect(state.isActive == true)
    }

    @Test("isActive returns false for disconnected")
    func isActiveDisconnected() {
        let state = ConnectionState.disconnected
        #expect(state.isActive == false)
    }

    @Test("isActive returns false for connecting")
    func isActiveConnecting() {
        let state = ConnectionState.connecting
        #expect(state.isActive == false)
    }

    @Test("isActive returns false for tlsHandshake")
    func isActiveTlsHandshake() {
        let state = ConnectionState.tlsHandshake
        #expect(state.isActive == false)
    }

    @Test("isActive returns false for reconnecting")
    func isActiveReconnecting() {
        let state = ConnectionState.reconnecting(attempt: 1)
        #expect(state.isActive == false)
    }

    @Test("isActive returns false for closed")
    func isActiveClosed() {
        let state = ConnectionState.closed
        #expect(state.isActive == false)
    }

    // MARK: - canAcceptOperations Property Tests

    @Test("canAcceptOperations returns true only for connected")
    func canAcceptOperationsConnected() {
        let connected = ConnectionState.connected(Self.makeServerInfo())
        #expect(connected.canAcceptOperations == true)
    }

    @Test("canAcceptOperations returns false for disconnected")
    func canAcceptOperationsDisconnected() {
        #expect(ConnectionState.disconnected.canAcceptOperations == false)
    }

    @Test("canAcceptOperations returns false for connecting")
    func canAcceptOperationsConnecting() {
        #expect(ConnectionState.connecting.canAcceptOperations == false)
    }

    @Test("canAcceptOperations returns false for tlsHandshake")
    func canAcceptOperationsTlsHandshake() {
        #expect(ConnectionState.tlsHandshake.canAcceptOperations == false)
    }

    @Test("canAcceptOperations returns false for reconnecting")
    func canAcceptOperationsReconnecting() {
        #expect(ConnectionState.reconnecting(attempt: 1).canAcceptOperations == false)
    }

    @Test("canAcceptOperations returns false for draining")
    func canAcceptOperationsDraining() {
        #expect(ConnectionState.draining.canAcceptOperations == false)
    }

    @Test("canAcceptOperations returns false for closed")
    func canAcceptOperationsClosed() {
        #expect(ConnectionState.closed.canAcceptOperations == false)
    }

    // MARK: - serverInfo Property Tests

    @Test("serverInfo returns info when connected")
    func serverInfoWhenConnected() {
        let info = Self.makeServerInfo(serverId: "test-123")
        let state = ConnectionState.connected(info)
        #expect(state.serverInfo?.serverId == "test-123")
    }

    @Test("serverInfo returns nil when disconnected")
    func serverInfoWhenDisconnected() {
        #expect(ConnectionState.disconnected.serverInfo == nil)
    }

    @Test("serverInfo returns nil when connecting")
    func serverInfoWhenConnecting() {
        #expect(ConnectionState.connecting.serverInfo == nil)
    }

    @Test("serverInfo returns nil when reconnecting")
    func serverInfoWhenReconnecting() {
        #expect(ConnectionState.reconnecting(attempt: 1).serverInfo == nil)
    }

    @Test("serverInfo returns nil when closed")
    func serverInfoWhenClosed() {
        #expect(ConnectionState.closed.serverInfo == nil)
    }
}

@Suite("ConnectionStateMachine Tests")
struct ConnectionStateMachineTests {

    // MARK: - Test Helpers

    static func makeServerInfo() -> ServerInfo {
        ServerInfo(
            serverId: "test-server",
            serverName: "test",
            version: "2.10.0",
            proto: 1,
            host: "localhost",
            port: 4222,
            headers: true,
            maxPayload: 1048576
        )
    }

    // MARK: - Transitions from Disconnected

    @Test("Disconnected + connect -> connecting")
    func disconnectedToConnecting() {
        var machine = ConnectionStateMachine()
        #expect(machine.state == .disconnected)

        let newState = machine.transition(on: .connect)
        #expect(newState == .connecting)
        #expect(machine.state == .connecting)
    }

    @Test("Disconnected + close -> closed")
    func disconnectedToClosed() {
        var machine = ConnectionStateMachine()
        let newState = machine.transition(on: .close)
        #expect(newState == .closed)
        #expect(machine.state == .closed)
    }

    @Test("Disconnected + connected -> nil (invalid)")
    func disconnectedInvalidConnected() {
        var machine = ConnectionStateMachine()
        let newState = machine.transition(on: .connected(Self.makeServerInfo()))
        #expect(newState == nil)
        #expect(machine.state == .disconnected)
    }

    // MARK: - Transitions from Connecting

    @Test("Connecting + tlsRequired -> tlsHandshake")
    func connectingToTlsHandshake() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)

        let newState = machine.transition(on: .tlsRequired)
        #expect(newState == .tlsHandshake)
        #expect(machine.state == .tlsHandshake)
    }

    @Test("Connecting + connected -> connected")
    func connectingToConnected() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)

        let info = Self.makeServerInfo()
        let newState = machine.transition(on: .connected(info))
        #expect(newState == .connected(info))
        #expect(machine.state == .connected(info))
    }

    @Test("Connecting + disconnected -> disconnected")
    func connectingToDisconnected() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)

        let newState = machine.transition(on: .disconnected(nil))
        #expect(newState == .disconnected)
        #expect(machine.state == .disconnected)
    }

    @Test("Connecting + close -> closed")
    func connectingToClosed() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)

        let newState = machine.transition(on: .close)
        #expect(newState == .closed)
        #expect(machine.state == .closed)
    }

    // MARK: - Transitions from TLS Handshake

    @Test("TlsHandshake + tlsComplete -> connecting")
    func tlsHandshakeToConnecting() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .tlsRequired)

        let newState = machine.transition(on: .tlsComplete)
        #expect(newState == .connecting)
        #expect(machine.state == .connecting)
    }

    @Test("TlsHandshake + disconnected -> disconnected")
    func tlsHandshakeToDisconnected() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .tlsRequired)

        let newState = machine.transition(on: .disconnected(nil))
        #expect(newState == .disconnected)
        #expect(machine.state == .disconnected)
    }

    @Test("TlsHandshake + close -> closed")
    func tlsHandshakeToClosed() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .tlsRequired)

        let newState = machine.transition(on: .close)
        #expect(newState == .closed)
        #expect(machine.state == .closed)
    }

    // MARK: - Transitions from Connected

    @Test("Connected + disconnected -> disconnected")
    func connectedToDisconnected() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .connected(Self.makeServerInfo()))

        let newState = machine.transition(on: .disconnected(nil))
        #expect(newState == .disconnected)
        #expect(machine.state == .disconnected)
    }

    @Test("Connected + reconnecting -> reconnecting")
    func connectedToReconnecting() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .connected(Self.makeServerInfo()))

        let newState = machine.transition(on: .reconnecting(attempt: 1))
        #expect(newState == .reconnecting(attempt: 1))
        #expect(machine.state == .reconnecting(attempt: 1))
    }

    @Test("Connected + drain -> draining")
    func connectedToDraining() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .connected(Self.makeServerInfo()))

        let newState = machine.transition(on: .drain)
        #expect(newState == .draining)
        #expect(machine.state == .draining)
    }

    @Test("Connected + close -> closed")
    func connectedToClosed() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .connected(Self.makeServerInfo()))

        let newState = machine.transition(on: .close)
        #expect(newState == .closed)
        #expect(machine.state == .closed)
    }

    @Test("Connected + connect -> nil (invalid)")
    func connectedInvalidConnect() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .connected(Self.makeServerInfo()))

        let newState = machine.transition(on: .connect)
        #expect(newState == nil)
    }

    // MARK: - Transitions from Reconnecting

    @Test("Reconnecting + connected -> connected")
    func reconnectingToConnected() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .connected(Self.makeServerInfo()))
        _ = machine.transition(on: .reconnecting(attempt: 1))

        let info = Self.makeServerInfo()
        let newState = machine.transition(on: .connected(info))
        #expect(newState == .connected(info))
        #expect(machine.state == .connected(info))
    }

    @Test("Reconnecting + reconnecting (new attempt) -> reconnecting")
    func reconnectingToNextAttempt() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .connected(Self.makeServerInfo()))
        _ = machine.transition(on: .reconnecting(attempt: 1))

        let newState = machine.transition(on: .reconnecting(attempt: 2))
        #expect(newState == .reconnecting(attempt: 2))
        #expect(machine.state == .reconnecting(attempt: 2))
    }

    @Test("Reconnecting + disconnected -> disconnected")
    func reconnectingToDisconnected() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .connected(Self.makeServerInfo()))
        _ = machine.transition(on: .reconnecting(attempt: 1))

        let newState = machine.transition(on: .disconnected(nil))
        #expect(newState == .disconnected)
        #expect(machine.state == .disconnected)
    }

    @Test("Reconnecting + close -> closed")
    func reconnectingToClosed() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .connected(Self.makeServerInfo()))
        _ = machine.transition(on: .reconnecting(attempt: 1))

        let newState = machine.transition(on: .close)
        #expect(newState == .closed)
        #expect(machine.state == .closed)
    }

    // MARK: - Transitions from Draining

    @Test("Draining + disconnected -> disconnected")
    func drainingToDisconnected() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .connected(Self.makeServerInfo()))
        _ = machine.transition(on: .drain)

        let newState = machine.transition(on: .disconnected(nil))
        #expect(newState == .disconnected)
        #expect(machine.state == .disconnected)
    }

    @Test("Draining + close -> closed")
    func drainingToClosed() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .connected(Self.makeServerInfo()))
        _ = machine.transition(on: .drain)

        let newState = machine.transition(on: .close)
        #expect(newState == .closed)
        #expect(machine.state == .closed)
    }

    @Test("Draining + connect -> nil (invalid)")
    func drainingInvalidConnect() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .connected(Self.makeServerInfo()))
        _ = machine.transition(on: .drain)

        let newState = machine.transition(on: .connect)
        #expect(newState == nil)
    }

    // MARK: - Transitions from Closed

    @Test("Closed + any event -> nil (no transitions)")
    func closedNoTransitions() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .close)
        #expect(machine.state == .closed)

        // None of these should work
        #expect(machine.transition(on: .connect) == nil)
        #expect(machine.transition(on: .tlsRequired) == nil)
        #expect(machine.transition(on: .tlsComplete) == nil)
        #expect(machine.transition(on: .connected(Self.makeServerInfo())) == nil)
        #expect(machine.transition(on: .disconnected(nil)) == nil)
        #expect(machine.transition(on: .reconnecting(attempt: 1)) == nil)
        #expect(machine.transition(on: .drain) == nil)
        #expect(machine.transition(on: .close) == nil)

        // State should remain closed
        #expect(machine.state == .closed)
    }

    // MARK: - Force State Tests

    @Test("forceState can set any state from disconnected")
    func forceStateFromDisconnected() {
        var machine = ConnectionStateMachine()
        #expect(machine.state == .disconnected)

        machine.forceState(.connected(Self.makeServerInfo()))
        #expect(machine.state.serverInfo != nil)
    }

    @Test("forceState can set state even when closed")
    func forceStateFromClosed() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .close)
        #expect(machine.state == .closed)

        machine.forceState(.disconnected)
        #expect(machine.state == .disconnected)
    }

    @Test("forceState can set reconnecting directly")
    func forceStateToReconnecting() {
        var machine = ConnectionStateMachine()
        machine.forceState(.reconnecting(attempt: 5))
        #expect(machine.state == .reconnecting(attempt: 5))
    }
}
