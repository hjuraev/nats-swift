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
