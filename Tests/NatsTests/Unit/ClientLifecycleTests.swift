// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Nats

@Suite("Client Close Tests")
struct ClientCloseTests {

    @Test("Close transitions state to closed")
    func closeTransitionsState() async {
        let client = NatsClient {
            $0.reconnect = .disabled
        }

        // Initial state should be disconnected
        let initialState = await client.state
        #expect(initialState == .disconnected)

        // Close should transition to closed
        await client.close()
        let finalState = await client.state
        #expect(finalState == .closed)
    }

    @Test("Close on already closed client is idempotent")
    func closeIdempotent() async {
        let client = NatsClient {
            $0.reconnect = .disabled
        }

        await client.close()
        let stateAfterFirstClose = await client.state
        #expect(stateAfterFirstClose == .closed)

        // Calling close again should not crash or change state
        await client.close()
        let stateAfterSecondClose = await client.state
        #expect(stateAfterSecondClose == .closed)
    }

    @Test("Close completes quickly without server connection")
    func closeCompletesQuickly() async throws {
        let client = NatsClient {
            $0.reconnect = .disabled
        }

        // Measure time for close to complete
        let start = ContinuousClock.now
        await client.close()
        let elapsed = ContinuousClock.now - start

        // Close should complete in under 1 second without a connection
        #expect(elapsed < .seconds(1))
    }
}

@Suite("Reconnection Cancellation Tests")
struct ReconnectionCancellationTests {

    @Test("Reconnection state resets on close")
    func reconnectionStateResetsOnClose() async {
        let reconnectionState = ReconnectionState(policy: .aggressive)

        // Start reconnecting and record some attempts
        await reconnectionState.startReconnecting()
        await reconnectionState.recordAttempt(error: nil)
        await reconnectionState.recordAttempt(error: nil)

        #expect(await reconnectionState.isReconnecting == true)
        #expect(await reconnectionState.attempt == 2)

        // Reset (simulating what happens on close)
        await reconnectionState.reset()

        #expect(await reconnectionState.isReconnecting == false)
        #expect(await reconnectionState.attempt == 0)
    }

    @Test("shouldContinue returns false after max attempts")
    func shouldContinueRespectsMaxAttempts() async {
        let policy = ReconnectPolicy(
            enabled: true,
            maxAttempts: 2
        )
        let state = ReconnectionState(policy: policy)

        await state.startReconnecting()
        #expect(await state.shouldContinue() == true)

        await state.recordAttempt(error: nil)
        #expect(await state.shouldContinue() == true)

        await state.recordAttempt(error: nil)
        #expect(await state.shouldContinue() == false)
    }
}

@Suite("State Machine Close Behavior Tests")
struct StateMachineCloseBehaviorTests {

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

    @Test("Close from connected state works")
    func closeFromConnected() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .connected(Self.makeServerInfo()))
        #expect(machine.state.isActive == true)

        let newState = machine.transition(on: .close)
        #expect(newState == .closed)
        #expect(machine.state == .closed)
    }

    @Test("Close from reconnecting state works")
    func closeFromReconnecting() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        _ = machine.transition(on: .connected(Self.makeServerInfo()))
        _ = machine.transition(on: .reconnecting(attempt: 1))

        let newState = machine.transition(on: .close)
        #expect(newState == .closed)
        #expect(machine.state == .closed)
    }

    @Test("Close from connecting state works")
    func closeFromConnecting() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .connect)
        #expect(machine.state == .connecting)

        let newState = machine.transition(on: .close)
        #expect(newState == .closed)
        #expect(machine.state == .closed)
    }

    @Test("No transitions allowed from closed state")
    func noTransitionsFromClosed() {
        var machine = ConnectionStateMachine()
        _ = machine.transition(on: .close)
        #expect(machine.state == .closed)

        // Attempt various transitions - all should fail
        #expect(machine.transition(on: .connect) == nil)
        #expect(machine.transition(on: .connected(Self.makeServerInfo())) == nil)
        #expect(machine.transition(on: .reconnecting(attempt: 1)) == nil)
        #expect(machine.transition(on: .disconnected(nil)) == nil)

        // State should remain closed
        #expect(machine.state == .closed)
    }

    @Test("Closed state isActive returns false")
    func closedIsNotActive() {
        let state = ConnectionState.closed
        #expect(state.isActive == false)
        #expect(state.canAcceptOperations == false)
    }
}

@Suite("Task Cancellation Tests")
struct TaskCancellationTests {

    @Test("Task.isCancelled is detected correctly")
    func taskCancellationDetected() async {
        let task = Task { () -> Bool in
            // Simulate reconnection loop checking cancellation
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return true  // wasCancelled
        }

        // Cancel the task
        task.cancel()

        // Wait for task to complete
        let wasCancelled = await task.value

        #expect(wasCancelled == true)
    }

    @Test("Task.sleep throws on cancellation")
    func taskSleepThrowsOnCancellation() async {
        let task = Task { () -> Bool in
            do {
                try await Task.sleep(for: .seconds(10))
                return false
            } catch {
                return error is CancellationError
            }
        }

        // Small delay to ensure task started
        try? await Task.sleep(for: .milliseconds(10))

        // Cancel the task
        task.cancel()

        // Wait for task to complete
        let caughtCancellation = await task.value

        #expect(caughtCancellation == true)
    }

    @Test("Reconnection loop pattern exits on cancellation")
    func reconnectionLoopExitsOnCancellation() async {
        let policy = ReconnectPolicy(
            enabled: true,
            maxAttempts: -1,  // Unlimited
            initialDelay: .milliseconds(100)
        )
        let state = ReconnectionState(policy: policy)

        await state.startReconnecting()

        let task = Task { () -> (loopExited: Bool, exitReason: String) in
            var exitReason = ""

            while await state.shouldContinue() {
                // Check if cancelled before sleep
                guard !Task.isCancelled else {
                    exitReason = "cancelled_before_sleep"
                    break
                }

                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    exitReason = "sleep_cancelled"
                    break
                }

                // Check if cancelled after sleep
                guard !Task.isCancelled else {
                    exitReason = "cancelled_after_sleep"
                    break
                }

                await state.recordAttempt(error: nil)
            }
            return (loopExited: true, exitReason: exitReason)
        }

        // Let the loop run a bit
        try? await Task.sleep(for: .milliseconds(50))

        // Cancel it
        task.cancel()

        // Wait for completion
        let result = await task.value

        #expect(result.loopExited == true)
        #expect(result.exitReason != "")
    }
}
