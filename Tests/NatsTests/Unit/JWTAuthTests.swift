// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
@testable import Nats

@Suite("JWTCredentials Tests")
struct JWTCredentialsTests {

    // MARK: - Initialization Tests

    @Test("Initialize with JWT and valid seed")
    func initWithJWTAndSeed() throws {
        let credentials = try JWTCredentials(
            jwt: TestCredentials.sampleJWT,
            nkeySeed: TestCredentials.validUserSeed
        )

        #expect(credentials.jwt == TestCredentials.sampleJWT)
        #expect(credentials.nkeySeed == TestCredentials.validUserSeed)
        #expect(credentials.publicKey.hasPrefix("U"))
    }

    @Test("Initialize with invalid seed throws")
    func initWithInvalidSeed() throws {
        #expect(throws: NKeyError.self) {
            _ = try JWTCredentials(
                jwt: TestCredentials.sampleJWT,
                nkeySeed: TestCredentials.invalidPrefixSeed
            )
        }
    }

    @Test("Initialize with too short seed throws")
    func initWithTooShortSeed() throws {
        #expect(throws: NKeyError.self) {
            _ = try JWTCredentials(
                jwt: TestCredentials.sampleJWT,
                nkeySeed: TestCredentials.tooShortSeed
            )
        }
    }

    // MARK: - Parsing Tests

    @Test("Parse valid credentials content")
    func parseValidContent() throws {
        let credentials = try JWTCredentials.parse(TestCredentials.validCredsContent)

        #expect(credentials.jwt.count > 0)
        #expect(credentials.nkeySeed == TestCredentials.validUserSeed)
        #expect(credentials.publicKey.hasPrefix("U"))
    }

    @Test("Parse credentials with extra whitespace")
    func parseWithWhitespace() throws {
        let credentials = try JWTCredentials.parse(TestCredentials.validCredsWithWhitespace)

        #expect(credentials.jwt.count > 0)
        #expect(credentials.nkeySeed == TestCredentials.validUserSeed)
    }

    @Test("Parse missing JWT block throws")
    func parseMissingJWT() throws {
        #expect(throws: CredentialsError.self) {
            _ = try JWTCredentials.parse(TestCredentials.missingJWTBlock)
        }
    }

    @Test("Parse missing seed block throws")
    func parseMissingSeed() throws {
        #expect(throws: CredentialsError.self) {
            _ = try JWTCredentials.parse(TestCredentials.missingSeedBlock)
        }
    }

    @Test("Parse malformed content throws")
    func parseMalformedContent() throws {
        #expect(throws: CredentialsError.self) {
            _ = try JWTCredentials.parse(TestCredentials.malformedCredsContent)
        }
    }

    @Test("Parse empty content throws")
    func parseEmptyContent() throws {
        #expect(throws: CredentialsError.self) {
            _ = try JWTCredentials.parse(TestCredentials.emptyContent)
        }
    }

    @Test("Parse random content throws")
    func parseRandomContent() throws {
        #expect(throws: CredentialsError.self) {
            _ = try JWTCredentials.parse(TestCredentials.randomContent)
        }
    }

    // MARK: - Signing Tests

    @Test("Sign nonce produces base64 signature")
    func signNonce() throws {
        let credentials = try JWTCredentials(
            jwt: TestCredentials.sampleJWT,
            nkeySeed: TestCredentials.validUserSeed
        )

        let signature = try credentials.sign(nonce: TestCredentials.sampleNonce)

        #expect(signature.count > 0)
        #expect(Data(base64Encoded: signature) != nil)
    }

    @Test("Sign same nonce produces valid signatures")
    func signSameNonce() throws {
        let credentials = try JWTCredentials(
            jwt: TestCredentials.sampleJWT,
            nkeySeed: TestCredentials.validUserSeed
        )

        let sig1 = try credentials.sign(nonce: "test")
        let sig2 = try credentials.sign(nonce: "test")

        // Both should be valid base64
        #expect(Data(base64Encoded: sig1) != nil)
        #expect(Data(base64Encoded: sig2) != nil)

        // Note: Swift Crypto's signatures may not be deterministic
    }

    @Test("Sign different nonces produces different signatures")
    func signDifferentNonces() throws {
        let credentials = try JWTCredentials(
            jwt: TestCredentials.sampleJWT,
            nkeySeed: TestCredentials.validUserSeed
        )

        let sig1 = try credentials.sign(nonce: "nonce1")
        let sig2 = try credentials.sign(nonce: "nonce2")

        #expect(sig1 != sig2)
    }

    @Test("Sign empty nonce")
    func signEmptyNonce() throws {
        let credentials = try JWTCredentials(
            jwt: TestCredentials.sampleJWT,
            nkeySeed: TestCredentials.validUserSeed
        )

        let signature = try credentials.sign(nonce: "")

        #expect(signature.count > 0)
    }

    // MARK: - Public Key Tests

    @Test("Public key is accessible")
    func publicKeyAccessible() throws {
        let credentials = try JWTCredentials(
            jwt: TestCredentials.sampleJWT,
            nkeySeed: TestCredentials.validUserSeed
        )

        let publicKey = credentials.publicKey

        #expect(publicKey.hasPrefix("U"))
        #expect(publicKey.count > 0)
    }

    @Test("Public key matches direct NKey auth")
    func publicKeyMatchesNKey() throws {
        let credentials = try JWTCredentials(
            jwt: TestCredentials.sampleJWT,
            nkeySeed: TestCredentials.validUserSeed
        )

        let authenticator = try NKeyAuthenticator(seed: TestCredentials.validUserSeed)

        #expect(credentials.publicKey == authenticator.publicKey)
    }

    // MARK: - JWT Property Tests

    @Test("JWT property returns original value")
    func jwtPropertyReturnsOriginal() throws {
        let originalJWT = "my.custom.jwt"
        let credentials = try JWTCredentials(
            jwt: originalJWT,
            nkeySeed: TestCredentials.validUserSeed
        )

        #expect(credentials.jwt == originalJWT)
    }

    @Test("NKey seed property returns original value")
    func nkeySeedPropertyReturnsOriginal() throws {
        let credentials = try JWTCredentials(
            jwt: TestCredentials.sampleJWT,
            nkeySeed: TestCredentials.validUserSeed
        )

        #expect(credentials.nkeySeed == TestCredentials.validUserSeed)
    }
}

@Suite("CredentialsError Tests")
struct CredentialsErrorTests {

    @Test("invalidFormat error description")
    func invalidFormatDescription() {
        let error = CredentialsError.invalidFormat
        #expect(error.description.contains("Invalid credentials file format"))
    }

    @Test("fileNotFound error description")
    func fileNotFoundDescription() {
        let error = CredentialsError.fileNotFound("/path/to/file")
        #expect(error.description.contains("Credentials file not found"))
        #expect(error.description.contains("/path/to/file"))
    }

    @Test("readError error description")
    func readErrorDescription() {
        let error = CredentialsError.readError("test reason")
        #expect(error.description.contains("Error reading credentials"))
        #expect(error.description.contains("test reason"))
    }
}
