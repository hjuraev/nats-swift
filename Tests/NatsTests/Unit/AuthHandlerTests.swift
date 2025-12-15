// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
@testable import Nats

@Suite("AuthHandler Tests")
struct AuthHandlerTests {

    // MARK: - No Auth Tests

    @Test("Build fields with no auth returns all nil")
    func buildFieldsNoAuth() throws {
        let handler = AuthHandler(config: .none)
        let fields = try handler.buildAuthFields(nonce: nil)

        #expect(fields.authToken == nil)
        #expect(fields.user == nil)
        #expect(fields.pass == nil)
        #expect(fields.jwt == nil)
        #expect(fields.nkey == nil)
        #expect(fields.sig == nil)
    }

    @Test("Build fields with no auth ignores nonce")
    func buildFieldsNoAuthIgnoresNonce() throws {
        let handler = AuthHandler(config: .none)
        let fields = try handler.buildAuthFields(nonce: "some-nonce")

        #expect(fields.authToken == nil)
        #expect(fields.user == nil)
        #expect(fields.pass == nil)
        #expect(fields.jwt == nil)
        #expect(fields.nkey == nil)
        #expect(fields.sig == nil)
    }

    // MARK: - Token Auth Tests

    @Test("Build fields with token auth sets authToken")
    func buildFieldsTokenAuth() throws {
        let handler = AuthHandler(config: .token("secret-token"))
        let fields = try handler.buildAuthFields(nonce: nil)

        #expect(fields.authToken == "secret-token")
        #expect(fields.user == nil)
        #expect(fields.pass == nil)
        #expect(fields.jwt == nil)
        #expect(fields.nkey == nil)
        #expect(fields.sig == nil)
    }

    @Test("Build fields with token auth ignores nonce")
    func buildFieldsTokenAuthIgnoresNonce() throws {
        let handler = AuthHandler(config: .token("secret-token"))
        let fields = try handler.buildAuthFields(nonce: "some-nonce")

        #expect(fields.authToken == "secret-token")
        #expect(fields.sig == nil)
    }

    @Test("Build fields with empty token")
    func buildFieldsEmptyToken() throws {
        let handler = AuthHandler(config: .token(""))
        let fields = try handler.buildAuthFields(nonce: nil)

        #expect(fields.authToken == "")
    }

    // MARK: - User/Pass Auth Tests

    @Test("Build fields with user/pass auth sets user and pass")
    func buildFieldsUserPassAuth() throws {
        let handler = AuthHandler(config: .userPass(user: "admin", password: "password123"))
        let fields = try handler.buildAuthFields(nonce: nil)

        #expect(fields.user == "admin")
        #expect(fields.pass == "password123")
        #expect(fields.authToken == nil)
        #expect(fields.jwt == nil)
        #expect(fields.nkey == nil)
        #expect(fields.sig == nil)
    }

    @Test("Build fields with user/pass ignores nonce")
    func buildFieldsUserPassIgnoresNonce() throws {
        let handler = AuthHandler(config: .userPass(user: "admin", password: "pass"))
        let fields = try handler.buildAuthFields(nonce: "some-nonce")

        #expect(fields.user == "admin")
        #expect(fields.pass == "pass")
        #expect(fields.sig == nil)
    }

    @Test("Build fields with empty user and pass")
    func buildFieldsEmptyUserPass() throws {
        let handler = AuthHandler(config: .userPass(user: "", password: ""))
        let fields = try handler.buildAuthFields(nonce: nil)

        #expect(fields.user == "")
        #expect(fields.pass == "")
    }

    // MARK: - NKey Auth Tests

    @Test("Build fields with NKey auth sets nkey")
    func buildFieldsNKeyAuth() throws {
        let handler = AuthHandler(config: .nkey(seed: TestCredentials.validUserSeed))
        let fields = try handler.buildAuthFields(nonce: nil)

        #expect(fields.nkey != nil)
        #expect(fields.nkey!.hasPrefix("U"))
        #expect(fields.sig == nil)  // No sig without nonce
        #expect(fields.authToken == nil)
        #expect(fields.user == nil)
        #expect(fields.pass == nil)
        #expect(fields.jwt == nil)
    }

    @Test("Build fields with NKey auth and nonce sets sig")
    func buildFieldsNKeyAuthWithNonce() throws {
        let handler = AuthHandler(config: .nkey(seed: TestCredentials.validUserSeed))
        let fields = try handler.buildAuthFields(nonce: TestCredentials.sampleNonce)

        #expect(fields.nkey != nil)
        #expect(fields.nkey!.hasPrefix("U"))
        #expect(fields.sig != nil)
        #expect(Data(base64Encoded: fields.sig!) != nil)
    }

    @Test("Build fields with invalid NKey throws")
    func buildFieldsInvalidNKey() throws {
        let handler = AuthHandler(config: .nkey(seed: TestCredentials.invalidPrefixSeed))

        #expect(throws: NKeyError.self) {
            _ = try handler.buildAuthFields(nonce: nil)
        }
    }

    @Test("Build fields with NKey produces consistent public key")
    func buildFieldsNKeyConsistentPublicKey() throws {
        let handler = AuthHandler(config: .nkey(seed: TestCredentials.validUserSeed))

        let fields1 = try handler.buildAuthFields(nonce: "nonce1")
        let fields2 = try handler.buildAuthFields(nonce: "nonce2")

        #expect(fields1.nkey == fields2.nkey)
    }

    @Test("Build fields with NKey produces different signatures for different nonces")
    func buildFieldsNKeyDifferentSigs() throws {
        let handler = AuthHandler(config: .nkey(seed: TestCredentials.validUserSeed))

        let fields1 = try handler.buildAuthFields(nonce: "nonce1")
        let fields2 = try handler.buildAuthFields(nonce: "nonce2")

        #expect(fields1.sig != fields2.sig)
    }

    // MARK: - JWT Auth Tests

    @Test("Build fields with JWT auth sets jwt and nkey")
    func buildFieldsJWTAuth() throws {
        let handler = AuthHandler(config: .jwt(jwt: TestCredentials.sampleJWT, nkeySeed: TestCredentials.validUserSeed))
        let fields = try handler.buildAuthFields(nonce: nil)

        #expect(fields.jwt == TestCredentials.sampleJWT)
        #expect(fields.nkey != nil)
        #expect(fields.nkey!.hasPrefix("U"))
        #expect(fields.sig == nil)  // No sig without nonce
        #expect(fields.authToken == nil)
        #expect(fields.user == nil)
        #expect(fields.pass == nil)
    }

    @Test("Build fields with JWT auth and nonce sets sig")
    func buildFieldsJWTAuthWithNonce() throws {
        let handler = AuthHandler(config: .jwt(jwt: TestCredentials.sampleJWT, nkeySeed: TestCredentials.validUserSeed))
        let fields = try handler.buildAuthFields(nonce: TestCredentials.sampleNonce)

        #expect(fields.jwt == TestCredentials.sampleJWT)
        #expect(fields.nkey != nil)
        #expect(fields.sig != nil)
        #expect(Data(base64Encoded: fields.sig!) != nil)
    }

    @Test("Build fields with JWT and invalid seed throws")
    func buildFieldsJWTInvalidSeed() throws {
        let handler = AuthHandler(config: .jwt(jwt: "some.jwt", nkeySeed: TestCredentials.invalidPrefixSeed))

        #expect(throws: NKeyError.self) {
            _ = try handler.buildAuthFields(nonce: nil)
        }
    }

    @Test("Build fields with empty JWT and valid seed")
    func buildFieldsEmptyJWT() throws {
        let handler = AuthHandler(config: .jwt(jwt: "", nkeySeed: TestCredentials.validUserSeed))
        let fields = try handler.buildAuthFields(nonce: nil)

        #expect(fields.jwt == "")
        #expect(fields.nkey != nil)
    }
}

@Suite("AuthFields Tests")
struct AuthFieldsTests {

    @Test("Default initialization has all nil values")
    func defaultInit() {
        let fields = AuthFields()

        #expect(fields.authToken == nil)
        #expect(fields.user == nil)
        #expect(fields.pass == nil)
        #expect(fields.jwt == nil)
        #expect(fields.nkey == nil)
        #expect(fields.sig == nil)
    }

    @Test("Initialization with authToken only")
    func initWithAuthToken() {
        let fields = AuthFields(authToken: "token")

        #expect(fields.authToken == "token")
        #expect(fields.user == nil)
        #expect(fields.pass == nil)
    }

    @Test("Initialization with user and pass")
    func initWithUserPass() {
        let fields = AuthFields(user: "user", pass: "pass")

        #expect(fields.user == "user")
        #expect(fields.pass == "pass")
        #expect(fields.authToken == nil)
    }

    @Test("Initialization with jwt, nkey, and sig")
    func initWithJWTFields() {
        let fields = AuthFields(jwt: "jwt", nkey: "nkey", sig: "sig")

        #expect(fields.jwt == "jwt")
        #expect(fields.nkey == "nkey")
        #expect(fields.sig == "sig")
    }

    @Test("Initialization with all fields")
    func initWithAllFields() {
        let fields = AuthFields(
            authToken: "token",
            user: "user",
            pass: "pass",
            jwt: "jwt",
            nkey: "nkey",
            sig: "sig"
        )

        #expect(fields.authToken == "token")
        #expect(fields.user == "user")
        #expect(fields.pass == "pass")
        #expect(fields.jwt == "jwt")
        #expect(fields.nkey == "nkey")
        #expect(fields.sig == "sig")
    }
}
