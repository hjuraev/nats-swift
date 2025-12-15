// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Reconnection policy configuration
public struct ReconnectPolicy: Sendable {
    /// Whether reconnection is enabled
    public var enabled: Bool

    /// Maximum number of reconnection attempts (-1 for unlimited)
    public var maxAttempts: Int

    /// Initial delay before first reconnection attempt
    public var initialDelay: Duration

    /// Maximum delay between reconnection attempts
    public var maxDelay: Duration

    /// Randomization factor for jitter (0.0 to 1.0)
    public var jitter: Double

    /// Multiplier for exponential backoff
    public var backoffMultiplier: Double

    public init(
        enabled: Bool = true,
        maxAttempts: Int = 60,
        initialDelay: Duration = .milliseconds(100),
        maxDelay: Duration = .seconds(5),
        jitter: Double = 0.1,
        backoffMultiplier: Double = 2.0
    ) {
        self.enabled = enabled
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.jitter = min(1.0, max(0.0, jitter))  // Clamp to [0, 1]
        self.backoffMultiplier = max(1.0, backoffMultiplier)
    }

    /// Calculate delay for a given attempt number
    public func delay(forAttempt attempt: Int) -> Duration {
        guard attempt > 0 else { return initialDelay }

        // Calculate base delay with exponential backoff
        let multiplier = pow(backoffMultiplier, Double(attempt - 1))
        let baseNanos = Double(initialDelay.components.seconds) * 1_000_000_000
            + Double(initialDelay.components.attoseconds) / 1_000_000_000
        let delayNanos = baseNanos * multiplier

        // Apply jitter
        let jitterRange = delayNanos * jitter
        let jitterOffset = Double.random(in: -jitterRange...jitterRange)
        let finalNanos = max(0, delayNanos + jitterOffset)

        // Cap at max delay
        let maxNanos = Double(maxDelay.components.seconds) * 1_000_000_000
            + Double(maxDelay.components.attoseconds) / 1_000_000_000

        let cappedNanos = min(finalNanos, maxNanos)
        return .nanoseconds(Int64(cappedNanos))
    }

    /// Check if more reconnection attempts are allowed
    public func shouldReconnect(attempt: Int) -> Bool {
        guard enabled else { return false }
        if maxAttempts < 0 { return true }  // Unlimited
        return attempt < maxAttempts
    }
}

// MARK: - Presets

extension ReconnectPolicy {
    /// No reconnection
    public static var disabled: ReconnectPolicy {
        ReconnectPolicy(enabled: false)
    }

    /// Aggressive reconnection for high-availability
    public static var aggressive: ReconnectPolicy {
        ReconnectPolicy(
            enabled: true,
            maxAttempts: -1,  // Unlimited
            initialDelay: .milliseconds(50),
            maxDelay: .seconds(2),
            jitter: 0.2
        )
    }

    /// Conservative reconnection
    public static var conservative: ReconnectPolicy {
        ReconnectPolicy(
            enabled: true,
            maxAttempts: 10,
            initialDelay: .seconds(1),
            maxDelay: .seconds(30),
            jitter: 0.1
        )
    }
}

// MARK: - Reconnection State

/// Tracks reconnection state
actor ReconnectionState {
    private(set) var attempt: Int = 0
    private(set) var isReconnecting: Bool = false
    private(set) var lastError: Error?
    private let policy: ReconnectPolicy

    init(policy: ReconnectPolicy) {
        self.policy = policy
    }

    func startReconnecting() {
        isReconnecting = true
        attempt = 0
    }

    func recordAttempt(error: Error?) {
        attempt += 1
        lastError = error
    }

    func reset() {
        attempt = 0
        isReconnecting = false
        lastError = nil
    }

    func shouldContinue() -> Bool {
        policy.shouldReconnect(attempt: attempt)
    }

    func nextDelay() -> Duration {
        policy.delay(forAttempt: attempt)
    }
}
