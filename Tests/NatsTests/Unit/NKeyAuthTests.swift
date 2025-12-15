// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
@testable import Nats

@Suite("NKeyAuthenticator Tests")
struct NKeyAuthenticatorTests {

    // MARK: - Initialization Tests

    @Test("Initialize with valid seed")
    func initWithValidSeed() throws {
        let authenticator = try NKeyAuthenticator(seed: TestCredentials.validUserSeed)

        // Public key should start with 'U' for user keys
        #expect(authenticator.publicKey.hasPrefix("U"))
        #expect(authenticator.publicKey.count > 0)
    }

    @Test("Initialize with invalid prefix throws")
    func initWithInvalidPrefix() throws {
        #expect(throws: NKeyError.self) {
            _ = try NKeyAuthenticator(seed: TestCredentials.invalidPrefixSeed)
        }
    }

    @Test("Initialize with too short seed throws")
    func initWithTooShortSeed() throws {
        #expect(throws: NKeyError.self) {
            _ = try NKeyAuthenticator(seed: TestCredentials.tooShortSeed)
        }
    }

    @Test("Initialize with invalid base32 chars throws")
    func initWithInvalidBase32() throws {
        #expect(throws: NKeyError.self) {
            _ = try NKeyAuthenticator(seed: TestCredentials.invalidBase32Seed)
        }
    }

    @Test("Initialize with invalid checksum throws")
    func initWithInvalidChecksum() throws {
        #expect(throws: NKeyError.self) {
            _ = try NKeyAuthenticator(seed: TestCredentials.invalidChecksumSeed)
        }
    }

    @Test("Initialize with empty seed throws")
    func initWithEmptySeed() throws {
        #expect(throws: NKeyError.self) {
            _ = try NKeyAuthenticator(seed: "")
        }
    }

    @Test("Initialize with single character seed throws")
    func initWithSingleCharSeed() throws {
        #expect(throws: NKeyError.self) {
            _ = try NKeyAuthenticator(seed: "S")
        }
    }

    // MARK: - Public Key Tests

    @Test("Public key is deterministic")
    func publicKeyDeterministic() throws {
        let authenticator1 = try NKeyAuthenticator(seed: TestCredentials.validUserSeed)
        let authenticator2 = try NKeyAuthenticator(seed: TestCredentials.validUserSeed)

        #expect(authenticator1.publicKey == authenticator2.publicKey)
    }

    @Test("Public key format is valid base32")
    func publicKeyFormatValid() throws {
        let authenticator = try NKeyAuthenticator(seed: TestCredentials.validUserSeed)
        let publicKey = authenticator.publicKey

        // Public key should only contain valid base32 characters
        let validChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let keyChars = CharacterSet(charactersIn: publicKey)
        #expect(validChars.isSuperset(of: keyChars))
    }

    // MARK: - Signing Tests

    @Test("Sign nonce produces base64 signature")
    func signNonceProducesBase64() throws {
        let authenticator = try NKeyAuthenticator(seed: TestCredentials.validUserSeed)
        let signature = try authenticator.sign(nonce: TestCredentials.sampleNonce)

        // Signature should be valid base64
        #expect(signature.count > 0)
        #expect(Data(base64Encoded: signature) != nil)
    }

    @Test("Sign same nonce produces valid base64 signature")
    func signSameNonceProducesValidSignature() throws {
        let authenticator = try NKeyAuthenticator(seed: TestCredentials.validUserSeed)

        let sig1 = try authenticator.sign(nonce: TestCredentials.sampleNonce)
        let sig2 = try authenticator.sign(nonce: TestCredentials.sampleNonce)

        // Both signatures should be valid base64
        #expect(Data(base64Encoded: sig1) != nil)
        #expect(Data(base64Encoded: sig2) != nil)

        // Both signatures should be 64 bytes (Ed25519)
        #expect(Data(base64Encoded: sig1)!.count == 64)
        #expect(Data(base64Encoded: sig2)!.count == 64)

        // Note: Swift Crypto's Curve25519.Signing may not be deterministic
        // (uses randomized variant), so we don't test sig1 == sig2
    }

    @Test("Sign different nonces produces different signatures")
    func signDifferentNoncesProducesDifferentSignatures() throws {
        let authenticator = try NKeyAuthenticator(seed: TestCredentials.validUserSeed)

        let sig1 = try authenticator.sign(nonce: "nonce1")
        let sig2 = try authenticator.sign(nonce: "nonce2")

        #expect(sig1 != sig2)
    }

    @Test("Sign empty nonce produces signature")
    func signEmptyNonce() throws {
        let authenticator = try NKeyAuthenticator(seed: TestCredentials.validUserSeed)
        let signature = try authenticator.sign(nonce: TestCredentials.emptyNonce)

        #expect(signature.count > 0)
        #expect(Data(base64Encoded: signature) != nil)
    }

    @Test("Sign nonce with special characters")
    func signSpecialCharNonce() throws {
        let authenticator = try NKeyAuthenticator(seed: TestCredentials.validUserSeed)
        let signature = try authenticator.sign(nonce: TestCredentials.specialNonce)

        #expect(signature.count > 0)
        #expect(Data(base64Encoded: signature) != nil)
    }

    @Test("Sign raw data produces data")
    func signRawData() throws {
        let authenticator = try NKeyAuthenticator(seed: TestCredentials.validUserSeed)
        let data = "test data".data(using: .utf8)!

        let signature = try authenticator.sign(data: data)

        // Ed25519 signatures are 64 bytes
        #expect(signature.count == 64)
    }

    @Test("Sign same raw data produces valid signatures")
    func signSameRawDataProducesValidSignatures() throws {
        let authenticator = try NKeyAuthenticator(seed: TestCredentials.validUserSeed)
        let data = "test data".data(using: .utf8)!

        let sig1 = try authenticator.sign(data: data)
        let sig2 = try authenticator.sign(data: data)

        // Both should be 64 bytes (Ed25519 signature size)
        #expect(sig1.count == 64)
        #expect(sig2.count == 64)

        // Note: Swift Crypto's Curve25519.Signing may not be deterministic
    }

    @Test("Sign empty data produces signature")
    func signEmptyData() throws {
        let authenticator = try NKeyAuthenticator(seed: TestCredentials.validUserSeed)
        let data = Data()

        let signature = try authenticator.sign(data: data)

        #expect(signature.count == 64)
    }

    // MARK: - Ed25519 Signature Properties

    @Test("Signature length is correct for Ed25519")
    func signatureLengthCorrect() throws {
        let authenticator = try NKeyAuthenticator(seed: TestCredentials.validUserSeed)
        let signature = try authenticator.sign(nonce: "test")

        // Base64 encoded 64-byte Ed25519 signature should be 88 characters
        // (64 bytes = 86.67 base64 chars, rounded up with padding = 88)
        #expect(signature.count == 88)
    }
}

@Suite("NKeyError Tests")
struct NKeyErrorTests {

    @Test("invalidSeed error description")
    func invalidSeedDescription() {
        let error = NKeyError.invalidSeed("test reason")
        #expect(error.description.contains("Invalid NKey seed"))
        #expect(error.description.contains("test reason"))
    }

    @Test("invalidNonce error description")
    func invalidNonceDescription() {
        let error = NKeyError.invalidNonce
        #expect(error.description.contains("Invalid nonce"))
    }

    @Test("signingFailed error description")
    func signingFailedDescription() {
        let error = NKeyError.signingFailed("test reason")
        #expect(error.description.contains("Signing failed"))
        #expect(error.description.contains("test reason"))
    }
}
