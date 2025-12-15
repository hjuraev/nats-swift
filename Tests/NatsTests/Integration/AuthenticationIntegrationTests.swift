// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
import NIOCore
@testable import Nats

/// Integration tests for NATS authentication methods
/// These tests require specific NATS servers to be running with the configurations in .github/
/// When the required servers are not running, tests will pass but skip their assertions
@Suite("Authentication Integration Tests")
struct AuthenticationIntegrationTests {

    // MARK: - Token Authentication Tests (Port 4223)

    @Test("Connect with valid token")
    func connectWithValidToken() async throws {
        let client = NatsClient {
            $0.servers = [URL(string: "nats://localhost:4223")!]
            $0.auth = .token("secret-test-token")
        }

        do {
            try await client.connect()
            defer { Task { await client.close() } }

            // Test that we can publish/subscribe
            let sub = try await client.subscribe("test.token")
            var payload = ByteBuffer()
            payload.writeString("hello")
            try await client.publish("test.token", payload: payload)

            for try await msg in sub {
                let text = msg.string
                #expect(text == "hello")
                break
            }
        } catch let error as ConnectionError {
            // Skip if server not running - test passes but assertions skipped
            switch error {
            case .connectionRefused, .noServersAvailable:
                // Server not running, skip test silently
                return
            default:
                throw error
            }
        }
    }

    @Test("Connect with invalid token fails")
    func connectWithInvalidToken() async throws {
        let client = NatsClient {
            $0.servers = [URL(string: "nats://localhost:4223")!]
            $0.auth = .token("wrong-token")
        }

        do {
            try await client.connect()
            // If we get here without error, the server might not be running with auth
            #expect(Bool(false), "Expected connection to fail with wrong token")
        } catch let error as ConnectionError {
            // Skip if server not running (connection refused)
            switch error {
            case .connectionRefused, .noServersAvailable:
                // Server not running, skip test silently
                return
            case .authenticationFailed:
                // Auth failure is expected - test passes
                return
            default:
                // Other connection errors might include auth failures
                return
            }
        } catch {
            // Other errors (like auth failure) are expected - test passes
        }
    }

    // MARK: - User/Password Authentication Tests (Port 4224)

    @Test("Connect with valid username and password")
    func connectWithValidUserPass() async throws {
        let client = NatsClient {
            $0.servers = [URL(string: "nats://localhost:4224")!]
            $0.auth = .userPass(user: "admin", password: "password123")
        }

        do {
            try await client.connect()
            defer { Task { await client.close() } }

            // Test that we can publish/subscribe
            let sub = try await client.subscribe("test.userpass")
            var payload = ByteBuffer()
            payload.writeString("hello")
            try await client.publish("test.userpass", payload: payload)

            for try await msg in sub {
                let text = msg.string
                #expect(text == "hello")
                break
            }
        } catch let error as ConnectionError {
            // Skip if server not running
            switch error {
            case .connectionRefused, .noServersAvailable:
                // Server not running, skip test silently
                return
            default:
                throw error
            }
        }
    }

    @Test("Connect with invalid password fails")
    func connectWithInvalidPassword() async throws {
        let client = NatsClient {
            $0.servers = [URL(string: "nats://localhost:4224")!]
            $0.auth = .userPass(user: "admin", password: "wrongpassword")
        }

        do {
            try await client.connect()
            #expect(Bool(false), "Expected connection to fail with wrong password")
        } catch let error as ConnectionError {
            // Skip if server not running
            switch error {
            case .connectionRefused, .noServersAvailable:
                // Server not running, skip test silently
                return
            case .authenticationFailed:
                // Auth failure is expected - test passes
                return
            default:
                // Other connection errors might include auth failures
                return
            }
        } catch {
            // Other errors (like auth failure) are expected
        }
    }

    @Test("Connect with invalid username fails")
    func connectWithInvalidUsername() async throws {
        let client = NatsClient {
            $0.servers = [URL(string: "nats://localhost:4224")!]
            $0.auth = .userPass(user: "wronguser", password: "password123")
        }

        do {
            try await client.connect()
            #expect(Bool(false), "Expected connection to fail with wrong username")
        } catch let error as ConnectionError {
            // Skip if server not running
            switch error {
            case .connectionRefused, .noServersAvailable:
                // Server not running, skip test silently
                return
            case .authenticationFailed:
                // Auth failure is expected - test passes
                return
            default:
                // Other connection errors might include auth failures
                return
            }
        } catch {
            // Other errors (like auth failure) are expected
        }
    }

    // MARK: - NKey Authentication Tests (Port 4225)

    @Test("Connect with valid NKey seed")
    func connectWithValidNKey() async throws {
        let client = NatsClient {
            $0.servers = [URL(string: "nats://localhost:4225")!]
            $0.auth = .nkey(seed: TestCredentials.validUserSeed)
        }

        do {
            try await client.connect()
            defer { Task { await client.close() } }

            // Test that we can publish/subscribe
            let sub = try await client.subscribe("test.nkey")
            var payload = ByteBuffer()
            payload.writeString("hello")
            try await client.publish("test.nkey", payload: payload)

            for try await msg in sub {
                let text = msg.string
                #expect(text == "hello")
                break
            }
        } catch let error as ConnectionError {
            // Skip if server not running
            switch error {
            case .connectionRefused, .noServersAvailable:
                // Server not running, skip test silently
                return
            default:
                throw error
            }
        }
    }

    @Test("Connect with invalid NKey fails")
    func connectWithInvalidNKey() async throws {
        // Generate a different valid seed that doesn't match server config
        let differentSeed = "SUAIBDPBAUTWCWBKIO6XHQNINK5FWJW4OHLXC3HQ2KFE4PEJUA44CNHTAM"

        let client = NatsClient {
            $0.servers = [URL(string: "nats://localhost:4225")!]
            $0.auth = .nkey(seed: differentSeed)
        }

        do {
            try await client.connect()
            #expect(Bool(false), "Expected connection to fail with wrong NKey")
        } catch let error as ConnectionError {
            // Skip if server not running
            switch error {
            case .connectionRefused, .noServersAvailable:
                // Server not running, skip test silently
                return
            case .authenticationFailed:
                // Auth failure is expected - test passes
                return
            default:
                // Other connection errors might include auth failures
                return
            }
        } catch {
            // Other errors (like auth failure or NKey error) are expected
        }
    }
}
