// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Test credentials for authentication testing
enum TestCredentials {

    // MARK: - Valid NKey Seeds

    /// A valid NKey user seed for testing (generated with correct CRC16 checksum)
    static let validUserSeed = "SUAACAQDAQCQMBYIBEFAWDANBYHRAEISCMKBKFQXDAMRUGY4DUPB6IDSHY"

    // MARK: - Invalid Seeds for Error Testing

    /// Seed missing 'S' prefix
    static let invalidPrefixSeed = "AUACSSL3UAHUDXKFSNVUZRF5UHPMWZ6BFDTJ7M6USDXIEDNPPQYYYCU3VY"

    /// Seed that is too short
    static let tooShortSeed = "SUACSS"

    /// Seed with invalid base32 characters
    static let invalidBase32Seed = "SUACSSL3UAHUD0KF1NVUZRF5UHPMWZ6BFDTJ7M6USDXIED8PPQYYYCU3VY"

    /// Seed with invalid checksum (last few chars modified)
    static let invalidChecksumSeed = "SUACSSL3UAHUDXKFSNVUZRF5UHPMWZ6BFDTJ7M6USDXIEDNPPQYYYCU3XX"

    // MARK: - Valid Credentials File

    /// Valid .creds file content
    static let validCredsContent = """
    -----BEGIN NATS USER JWT-----
    eyJhbGciOiJFZDI1NTE5IiwidHlwIjoiSldUIn0.eyJqdGkiOiJURVNUX0pXVF9JRCIsImlhdCI6MTcwMDAwMDAwMCwiaXNzIjoiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBIiwic3ViIjoiVUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEiLCJuYXRzIjp7InB1YiI6e30sInN1YiI6e30sInN1YnMiOi0xLCJkYXRhIjotMSwicGF5bG9hZCI6LTF9fQ.TEST_SIGNATURE
    -----END NATS USER JWT-----

    -----BEGIN USER NKEY SEED-----
    SUAACAQDAQCQMBYIBEFAWDANBYHRAEISCMKBKFQXDAMRUGY4DUPB6IDSHY
    -----END USER NKEY SEED-----
    """

    /// Valid .creds content with extra whitespace
    static let validCredsWithWhitespace = """

      -----BEGIN NATS USER JWT-----

    eyJhbGciOiJFZDI1NTE5IiwidHlwIjoiSldUIn0.eyJqdGkiOiJURVNUIn0.SIG

      -----END NATS USER JWT-----


    -----BEGIN USER NKEY SEED-----
      SUAACAQDAQCQMBYIBEFAWDANBYHRAEISCMKBKFQXDAMRUGY4DUPB6IDSHY
    -----END USER NKEY SEED-----

    """

    // MARK: - Invalid Credentials Files

    /// Credentials file missing JWT block
    static let missingJWTBlock = """
    -----BEGIN USER NKEY SEED-----
    SUACSSL3UAHUDXKFSNVUZRF5UHPMWZ6BFDTJ7M6USDXIEDNPPQYYYCU3VY
    -----END USER NKEY SEED-----
    """

    /// Credentials file missing seed block
    static let missingSeedBlock = """
    -----BEGIN NATS USER JWT-----
    eyJhbGciOiJFZDI1NTE5IiwidHlwIjoiSldUIn0.eyJqdGkiOiJURVNUIn0.SIG
    -----END NATS USER JWT-----
    """

    /// Malformed credentials (missing end markers)
    static let malformedCredsContent = """
    -----BEGIN NATS USER JWT-----
    eyJhbGciOiJFZDI1NTE5IiwidHlwIjoiSldUIn0

    -----BEGIN USER NKEY SEED-----
    SUACSSL3UAHUDXKFSNVUZRF5UHPMWZ6BFDTJ7M6USDXIEDNPPQYYYCU3VY
    """

    /// Completely empty content
    static let emptyContent = ""

    /// Random invalid content
    static let randomContent = "This is not a valid credentials file"

    // MARK: - Test JWTs

    /// A sample JWT token for testing
    static let sampleJWT = "eyJhbGciOiJFZDI1NTE5IiwidHlwIjoiSldUIn0.eyJqdGkiOiJURVNUX0pXVCIsImlhdCI6MTcwMDAwMDAwMH0.TEST_SIG"

    // MARK: - Test Nonces

    /// A sample nonce for signing tests
    static let sampleNonce = "rAnDoMnOnCeVaLuE123"

    /// Empty nonce
    static let emptyNonce = ""

    /// Nonce with special characters
    static let specialNonce = "nonce!@#$%^&*()_+-=[]{}|;':\",./<>?"
}
