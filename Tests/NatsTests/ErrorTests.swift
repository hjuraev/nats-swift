// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Nats

@Suite("Error Tests")
struct ErrorTests {

    @Test("ConnectionError descriptions")
    func connectionErrorDescriptions() {
        let errors: [ConnectionError] = [
            .invalidURL("nats://invalid url"),
            .connectionRefused(host: "localhost", port: 4222),
            .tlsHandshakeFailed(reason: "certificate expired"),
            .authenticationFailed(reason: "invalid token"),
            .maxReconnectsExceeded(attempts: 10),
            .serverShuttingDown,
            .timeout(after: .seconds(5)),
            .closed,
            .draining,
            .dnsResolutionFailed(host: "unknown.host"),
            .noServersAvailable,
            .tlsRequired,
            .io("socket error"),
        ]

        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }

    @Test("ProtocolError descriptions")
    func protocolErrorDescriptions() {
        let errors: [ProtocolError] = [
            .invalidSubject("foo bar"),
            .invalidHeader("invalid header format"),
            .payloadTooLarge(size: 2_000_000, max: 1_000_000),
            .staleConnection,
            .permissionViolation(operation: "publish", subject: "secret.>"),
            .serverError("test error"),
            .invalidMessage("malformed message"),
            .subscriptionNotFound(sid: "123"),
            .noResponders(subject: "api.test"),
            .invalidQueueGroup("invalid queue"),
        ]

        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }

    @Test("JetStreamError descriptions")
    func jetStreamErrorDescriptions() {
        let errors: [JetStreamError] = [
            .notEnabled,
            .streamNotFound("ORDERS"),
            .consumerNotFound(stream: "ORDERS", consumer: "processor"),
            .messageNotFound(stream: "ORDERS", sequence: 123),
            .duplicateMessage(stream: "ORDERS", sequence: 456),
            .invalidAck("malformed ack"),
            .timeout(operation: "fetch", after: .seconds(30)),
            .apiError(code: 404, errorCode: 10059, description: "stream not found"),
            .invalidStreamConfig("name required"),
            .invalidConsumerConfig("ack policy required"),
            .streamNameRequired,
            .consumerNameRequired,
            .invalidStreamName("invalid-name!"),
            .invalidConsumerName("invalid consumer"),
            .ackFailed("connection lost"),
            .pullFailed("timeout"),
            .publishFailed("no responders"),
            .notConnected,
            .cancelled,
            .transport("broken pipe"),
        ]

        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }

    @Test("NatsError wrapping")
    func natsErrorWrapping() {
        let connError = NatsError.connection(.closed)
        let protoError = NatsError.protocol(.staleConnection)
        let jsError = NatsError.jetStream(.notEnabled)
        let timeoutError = NatsError.timeout(operation: "request", after: .seconds(5))
        let cancelledError = NatsError.cancelled

        #expect(connError.description.contains("Connection"))
        #expect(protoError.description.contains("Protocol"))
        #expect(jsError.description.contains("JetStream"))
        #expect(timeoutError.description.contains("Timeout"))
        #expect(cancelledError.description.contains("cancelled"))
    }
}

// MARK: - Client Error Mapping

/// `JetStreamError.mapping` is what lets a caller tell "this deployment has no
/// JetStream" apart from "we are mid-reconnect". Everything used to arrive as
/// `.timeout`, so these cases pin the distinctions that gating logic relies on.
@Suite("JetStream client error mapping")
struct JetStreamErrorMappingTests {

    private let operation = "request"
    private let timeout = Duration.seconds(5)

    @Test("No responders on the JetStream API is a capability verdict")
    func noRespondersMapsToNotEnabled() {
        let mapped = JetStreamError.mapping(
            ProtocolError.noResponders(subject: "$JS.API.INFO"),
            operation: operation,
            timeout: timeout
        )

        #expect(mapped == .notEnabled)
        #expect(mapped.isJetStreamUnavailableVerdict)
    }

    @Test("A closed connection is transient, not a verdict")
    func closedConnectionMapsToNotConnected() {
        let mapped = JetStreamError.mapping(
            ConnectionError.closed,
            operation: operation,
            timeout: timeout
        )

        #expect(mapped == .notConnected)
        // The whole point: a reconnect window must never be cached as
        // "no JetStream here".
        #expect(!mapped.isJetStreamUnavailableVerdict)
    }

    @Test("Draining and exhausted reconnects are also transient")
    func otherTransientConnectionStates() {
        let draining = JetStreamError.mapping(
            ConnectionError.draining, operation: operation, timeout: timeout
        )
        let noServers = JetStreamError.mapping(
            ConnectionError.noServersAvailable, operation: operation, timeout: timeout
        )
        let exhausted = JetStreamError.mapping(
            ConnectionError.maxReconnectsExceeded(attempts: 10),
            operation: operation, timeout: timeout
        )

        #expect(draining == .notConnected)
        #expect(noServers == .notConnected)
        #expect(exhausted == .notConnected)
    }

    @Test("Cancellation is not reported as a timeout")
    func cancellationMapsToCancelled() {
        let mapped = JetStreamError.mapping(
            CancellationError(), operation: operation, timeout: timeout
        )

        #expect(mapped == .cancelled)
        #expect(!mapped.isJetStreamUnavailableVerdict)
    }

    @Test("Genuine timeouts stay timeouts and keep their operation")
    func timeoutsArePreserved() {
        let fromNats = JetStreamError.mapping(
            NatsError.timeout(operation: "fetch", after: .seconds(30)),
            operation: operation,
            timeout: timeout
        )
        let fromConnection = JetStreamError.mapping(
            ConnectionError.timeout(after: .seconds(2)),
            operation: operation,
            timeout: timeout
        )

        #expect(fromNats == .timeout(operation: "fetch", after: .seconds(30)))
        #expect(fromConnection == .timeout(operation: operation, after: timeout))
        #expect(!fromNats.isJetStreamUnavailableVerdict)
    }

    @Test("An existing JetStreamError passes through untouched")
    func jetStreamErrorsPassThrough() {
        let apiError = JetStreamError.apiError(
            code: 503, errorCode: 10039, description: "JetStream not enabled for account"
        )

        let mapped = JetStreamError.mapping(apiError, operation: operation, timeout: timeout)

        #expect(mapped == apiError)
        // Account-level refusal arrives as an API error, not `.notEnabled`, so
        // it is NOT a verdict this helper reports — callers match err_code 10039.
        #expect(!mapped.isJetStreamUnavailableVerdict)
    }

    @Test("NatsError wrappers are unwrapped, not flattened")
    func wrappedErrorsAreUnwrapped() {
        let wrappedConnection = JetStreamError.mapping(
            NatsError.connection(.closed), operation: operation, timeout: timeout
        )
        let wrappedProtocol = JetStreamError.mapping(
            NatsError.protocol(.noResponders(subject: "$JS.API.INFO")),
            operation: operation,
            timeout: timeout
        )
        let wrappedCancelled = JetStreamError.mapping(
            NatsError.cancelled, operation: operation, timeout: timeout
        )

        #expect(wrappedConnection == .notConnected)
        #expect(wrappedProtocol == .notEnabled)
        #expect(wrappedCancelled == .cancelled)
    }

    @Test("Unrecognized errors keep their description instead of becoming a timeout")
    func unknownErrorsBecomeTransport() {
        struct Weird: Error {}

        let mapped = JetStreamError.mapping(Weird(), operation: operation, timeout: timeout)

        guard case .transport(let reason) = mapped else {
            Issue.record("expected .transport, got \(mapped)")
            return
        }
        #expect(reason.contains("Weird"))
        #expect(!mapped.isJetStreamUnavailableVerdict)
    }

    @Test("Only notEnabled is a verdict")
    func verdictIsNarrow() {
        let nonVerdicts: [JetStreamError] = [
            .notConnected, .cancelled, .transport("x"),
            .timeout(operation: "request", after: .seconds(1)),
            .streamNotFound("ORDERS"),
            .apiError(code: 503, errorCode: 10039, description: "x"),
        ]

        #expect(JetStreamError.notEnabled.isJetStreamUnavailableVerdict)
        for error in nonVerdicts {
            #expect(!error.isJetStreamUnavailableVerdict)
        }
    }
}
