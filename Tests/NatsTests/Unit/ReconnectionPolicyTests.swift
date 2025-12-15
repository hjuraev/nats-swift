// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Nats

@Suite("ReconnectPolicy Tests")
struct ReconnectPolicyTests {

    // MARK: - Initialization Tests

    @Test("Default initialization values")
    func defaultInit() {
        let policy = ReconnectPolicy()

        #expect(policy.enabled == true)
        #expect(policy.maxAttempts == 60)
        #expect(policy.initialDelay == .milliseconds(100))
        #expect(policy.maxDelay == .seconds(5))
        #expect(policy.jitter == 0.1)
        #expect(policy.backoffMultiplier == 2.0)
    }

    @Test("Custom initialization")
    func customInit() {
        let policy = ReconnectPolicy(
            enabled: false,
            maxAttempts: 10,
            initialDelay: .seconds(1),
            maxDelay: .seconds(30),
            jitter: 0.5,
            backoffMultiplier: 3.0
        )

        #expect(policy.enabled == false)
        #expect(policy.maxAttempts == 10)
        #expect(policy.initialDelay == .seconds(1))
        #expect(policy.maxDelay == .seconds(30))
        #expect(policy.jitter == 0.5)
        #expect(policy.backoffMultiplier == 3.0)
    }

    @Test("Jitter clamped to maximum 1.0")
    func jitterClampedToMax() {
        let policy = ReconnectPolicy(jitter: 2.0)
        #expect(policy.jitter == 1.0)
    }

    @Test("Jitter clamped to minimum 0.0")
    func jitterClampedToMin() {
        let policy = ReconnectPolicy(jitter: -0.5)
        #expect(policy.jitter == 0.0)
    }

    @Test("Backoff multiplier minimum is 1.0")
    func backoffMultiplierMin() {
        let policy = ReconnectPolicy(backoffMultiplier: 0.5)
        #expect(policy.backoffMultiplier == 1.0)
    }

    @Test("Backoff multiplier at boundary")
    func backoffMultiplierBoundary() {
        let policy = ReconnectPolicy(backoffMultiplier: 1.0)
        #expect(policy.backoffMultiplier == 1.0)
    }

    // MARK: - Delay Calculation Tests

    @Test("Delay for attempt 0 returns initialDelay")
    func delayAttemptZero() {
        let policy = ReconnectPolicy(
            initialDelay: .milliseconds(100),
            jitter: 0  // No jitter for deterministic test
        )

        let delay = policy.delay(forAttempt: 0)
        #expect(delay == .milliseconds(100))
    }

    @Test("Delay for attempt 1 returns initialDelay")
    func delayAttemptOne() {
        let policy = ReconnectPolicy(
            initialDelay: .milliseconds(100),
            jitter: 0
        )

        let delay = policy.delay(forAttempt: 1)
        #expect(delay == .milliseconds(100))
    }

    @Test("Exponential backoff calculation")
    func exponentialBackoff() {
        let policy = ReconnectPolicy(
            initialDelay: .milliseconds(100),
            maxDelay: .seconds(60),  // High max to not interfere
            jitter: 0,
            backoffMultiplier: 2.0
        )

        // Attempt 1: 100ms
        let delay1 = policy.delay(forAttempt: 1)
        #expect(delay1 == .milliseconds(100))

        // Attempt 2: 100ms * 2 = 200ms
        let delay2 = policy.delay(forAttempt: 2)
        #expect(delay2 == .milliseconds(200))

        // Attempt 3: 100ms * 4 = 400ms
        let delay3 = policy.delay(forAttempt: 3)
        #expect(delay3 == .milliseconds(400))

        // Attempt 4: 100ms * 8 = 800ms
        let delay4 = policy.delay(forAttempt: 4)
        #expect(delay4 == .milliseconds(800))
    }

    @Test("Delay capped at maxDelay")
    func delayCappedAtMax() {
        let policy = ReconnectPolicy(
            initialDelay: .seconds(1),
            maxDelay: .seconds(5),
            jitter: 0,
            backoffMultiplier: 10.0  // Aggressive multiplier to quickly exceed max
        )

        // Attempt 1: 1s
        let delay1 = policy.delay(forAttempt: 1)
        #expect(delay1 == .seconds(1))

        // Attempt 2: 1s * 10 = 10s, but capped at 5s
        let delay2 = policy.delay(forAttempt: 2)
        #expect(delay2 == .seconds(5))

        // Attempt 3: would be 100s, but capped at 5s
        let delay3 = policy.delay(forAttempt: 3)
        #expect(delay3 == .seconds(5))
    }

    @Test("Jitter affects delay (non-deterministic)")
    func jitterAffectsDelay() {
        let policy = ReconnectPolicy(
            initialDelay: .seconds(1),
            maxDelay: .seconds(60),
            jitter: 0.5  // 50% jitter
        )

        // Run multiple times and verify we get different values
        var delays: Set<Int64> = []
        for _ in 0..<20 {
            let delay = policy.delay(forAttempt: 1)
            let nanos = delay.components.seconds * 1_000_000_000 + delay.components.attoseconds / 1_000_000_000
            delays.insert(nanos)
        }

        // With 50% jitter on 1s, we should get values between 0.5s and 1.5s
        // Highly unlikely to get the same value 20 times
        #expect(delays.count > 1)
    }

    @Test("Zero jitter produces consistent delays")
    func zeroJitterConsistent() {
        let policy = ReconnectPolicy(
            initialDelay: .milliseconds(100),
            jitter: 0
        )

        let delay1 = policy.delay(forAttempt: 2)
        let delay2 = policy.delay(forAttempt: 2)
        let delay3 = policy.delay(forAttempt: 2)

        #expect(delay1 == delay2)
        #expect(delay2 == delay3)
    }

    @Test("High attempt number doesn't overflow")
    func highAttemptNumber() {
        let policy = ReconnectPolicy(
            initialDelay: .milliseconds(100),
            maxDelay: .seconds(5),
            jitter: 0,
            backoffMultiplier: 2.0
        )

        // Very high attempt number - should just return maxDelay
        let delay = policy.delay(forAttempt: 100)
        #expect(delay == .seconds(5))
    }

    // MARK: - shouldReconnect Tests

    @Test("shouldReconnect returns false when disabled")
    func shouldReconnectDisabled() {
        let policy = ReconnectPolicy(enabled: false)

        #expect(policy.shouldReconnect(attempt: 0) == false)
        #expect(policy.shouldReconnect(attempt: 1) == false)
        #expect(policy.shouldReconnect(attempt: 100) == false)
    }

    @Test("shouldReconnect with unlimited attempts")
    func shouldReconnectUnlimited() {
        let policy = ReconnectPolicy(
            enabled: true,
            maxAttempts: -1  // Unlimited
        )

        #expect(policy.shouldReconnect(attempt: 0) == true)
        #expect(policy.shouldReconnect(attempt: 100) == true)
        #expect(policy.shouldReconnect(attempt: 1_000_000) == true)
    }

    @Test("shouldReconnect within max attempts")
    func shouldReconnectWithinMax() {
        let policy = ReconnectPolicy(
            enabled: true,
            maxAttempts: 5
        )

        #expect(policy.shouldReconnect(attempt: 0) == true)
        #expect(policy.shouldReconnect(attempt: 1) == true)
        #expect(policy.shouldReconnect(attempt: 4) == true)
    }

    @Test("shouldReconnect at max attempts returns false")
    func shouldReconnectAtMax() {
        let policy = ReconnectPolicy(
            enabled: true,
            maxAttempts: 5
        )

        #expect(policy.shouldReconnect(attempt: 5) == false)
        #expect(policy.shouldReconnect(attempt: 6) == false)
    }

    // MARK: - Preset Tests

    @Test("Disabled preset")
    func disabledPreset() {
        let policy = ReconnectPolicy.disabled
        #expect(policy.enabled == false)
    }

    @Test("Aggressive preset")
    func aggressivePreset() {
        let policy = ReconnectPolicy.aggressive

        #expect(policy.enabled == true)
        #expect(policy.maxAttempts == -1)  // Unlimited
        #expect(policy.initialDelay == .milliseconds(50))
        #expect(policy.maxDelay == .seconds(2))
        #expect(policy.jitter == 0.2)
    }

    @Test("Conservative preset")
    func conservativePreset() {
        let policy = ReconnectPolicy.conservative

        #expect(policy.enabled == true)
        #expect(policy.maxAttempts == 10)
        #expect(policy.initialDelay == .seconds(1))
        #expect(policy.maxDelay == .seconds(30))
        #expect(policy.jitter == 0.1)
    }
}

@Suite("ReconnectionState Tests")
struct ReconnectionStateTests {

    // MARK: - Initial State Tests

    @Test("Initial state values")
    func initialState() async {
        let policy = ReconnectPolicy()
        let state = ReconnectionState(policy: policy)

        let attempt = await state.attempt
        let isReconnecting = await state.isReconnecting
        let lastError = await state.lastError

        #expect(attempt == 0)
        #expect(isReconnecting == false)
        #expect(lastError == nil)
    }

    // MARK: - State Modification Tests

    @Test("startReconnecting sets flag and resets attempt")
    func startReconnecting() async {
        let policy = ReconnectPolicy()
        let state = ReconnectionState(policy: policy)

        // Record some attempts first
        await state.recordAttempt(error: nil)
        await state.recordAttempt(error: nil)

        // Start reconnecting
        await state.startReconnecting()

        let attempt = await state.attempt
        let isReconnecting = await state.isReconnecting

        #expect(attempt == 0)
        #expect(isReconnecting == true)
    }

    @Test("recordAttempt increments counter")
    func recordAttemptIncrements() async {
        let policy = ReconnectPolicy()
        let state = ReconnectionState(policy: policy)

        #expect(await state.attempt == 0)

        await state.recordAttempt(error: nil)
        #expect(await state.attempt == 1)

        await state.recordAttempt(error: nil)
        #expect(await state.attempt == 2)

        await state.recordAttempt(error: nil)
        #expect(await state.attempt == 3)
    }

    @Test("recordAttempt stores error")
    func recordAttemptStoresError() async {
        let policy = ReconnectPolicy()
        let state = ReconnectionState(policy: policy)

        struct TestError: Error {}

        await state.recordAttempt(error: TestError())
        let lastError = await state.lastError

        #expect(lastError != nil)
        #expect(lastError is TestError)
    }

    @Test("recordAttempt overwrites previous error")
    func recordAttemptOverwritesError() async {
        let policy = ReconnectPolicy()
        let state = ReconnectionState(policy: policy)

        struct Error1: Error {}
        struct Error2: Error {}

        await state.recordAttempt(error: Error1())
        await state.recordAttempt(error: Error2())

        let lastError = await state.lastError
        #expect(lastError is Error2)
    }

    @Test("reset clears all state")
    func resetClearsState() async {
        let policy = ReconnectPolicy()
        let state = ReconnectionState(policy: policy)

        struct TestError: Error {}

        // Set up some state
        await state.startReconnecting()
        await state.recordAttempt(error: TestError())
        await state.recordAttempt(error: nil)

        // Verify state is set
        #expect(await state.attempt == 2)
        #expect(await state.isReconnecting == true)

        // Reset
        await state.reset()

        // Verify everything is cleared
        #expect(await state.attempt == 0)
        #expect(await state.isReconnecting == false)
        #expect(await state.lastError == nil)
    }

    // MARK: - Delegation Tests

    @Test("shouldContinue delegates to policy")
    func shouldContinueDelegates() async {
        let policy = ReconnectPolicy(
            enabled: true,
            maxAttempts: 3
        )
        let state = ReconnectionState(policy: policy)

        // At attempt 0, should continue
        #expect(await state.shouldContinue() == true)

        // Record attempts up to limit
        await state.recordAttempt(error: nil)  // attempt = 1
        #expect(await state.shouldContinue() == true)

        await state.recordAttempt(error: nil)  // attempt = 2
        #expect(await state.shouldContinue() == true)

        await state.recordAttempt(error: nil)  // attempt = 3
        #expect(await state.shouldContinue() == false)
    }

    @Test("nextDelay delegates to policy")
    func nextDelayDelegates() async {
        let policy = ReconnectPolicy(
            initialDelay: .milliseconds(100),
            jitter: 0,
            backoffMultiplier: 2.0
        )
        let state = ReconnectionState(policy: policy)

        // At attempt 0
        let delay0 = await state.nextDelay()
        #expect(delay0 == .milliseconds(100))

        // At attempt 1
        await state.recordAttempt(error: nil)
        let delay1 = await state.nextDelay()
        #expect(delay1 == .milliseconds(100))

        // At attempt 2
        await state.recordAttempt(error: nil)
        let delay2 = await state.nextDelay()
        #expect(delay2 == .milliseconds(200))
    }

    @Test("Disabled policy always returns false for shouldContinue")
    func disabledPolicyShouldContinue() async {
        let policy = ReconnectPolicy.disabled
        let state = ReconnectionState(policy: policy)

        #expect(await state.shouldContinue() == false)

        await state.recordAttempt(error: nil)
        #expect(await state.shouldContinue() == false)
    }
}
