// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// JWT credentials authentication
public struct JWTCredentials: Sendable {
    /// The JWT token
    public let jwt: String

    /// The NKey seed for signing
    public let nkeySeed: String

    /// The NKey authenticator for signing
    private let authenticator: NKeyAuthenticator

    /// Initialize with JWT and NKey seed
    public init(jwt: String, nkeySeed: String) throws {
        self.jwt = jwt
        self.nkeySeed = nkeySeed
        self.authenticator = try NKeyAuthenticator(seed: nkeySeed)
    }

    /// Load credentials from a .creds file
    public static func load(from url: URL) throws -> JWTCredentials {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parse(content)
    }

    /// Load credentials from a file path
    public static func load(fromPath path: String) throws -> JWTCredentials {
        let url = URL(fileURLWithPath: path)
        return try load(from: url)
    }

    /// Parse credentials from content string
    public static func parse(_ content: String) throws -> JWTCredentials {
        // Credentials file format:
        // -----BEGIN NATS USER JWT-----
        // <jwt>
        // -----END NATS USER JWT-----
        //
        // -----BEGIN USER NKEY SEED-----
        // <seed>
        // -----END USER NKEY SEED-----

        let jwtPattern = "-----BEGIN NATS USER JWT-----\\s*([^-]+)\\s*-----END NATS USER JWT-----"
        let seedPattern = "-----BEGIN USER NKEY SEED-----\\s*([^-]+)\\s*-----END USER NKEY SEED-----"

        guard let jwtMatch = content.range(of: jwtPattern, options: .regularExpression),
              let seedMatch = content.range(of: seedPattern, options: .regularExpression) else {
            throw CredentialsError.invalidFormat
        }

        let jwtBlock = String(content[jwtMatch])
        let seedBlock = String(content[seedMatch])

        // Extract the actual JWT and seed values
        let jwt = extractValue(from: jwtBlock, start: "-----BEGIN NATS USER JWT-----", end: "-----END NATS USER JWT-----")
        let seed = extractValue(from: seedBlock, start: "-----BEGIN USER NKEY SEED-----", end: "-----END USER NKEY SEED-----")

        guard let jwt = jwt, let seed = seed else {
            throw CredentialsError.invalidFormat
        }

        return try JWTCredentials(jwt: jwt.trimmingCharacters(in: .whitespacesAndNewlines),
                                   nkeySeed: seed.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func extractValue(from block: String, start: String, end: String) -> String? {
        guard let startRange = block.range(of: start),
              let endRange = block.range(of: end) else {
            return nil
        }

        let valueStart = block.index(after: startRange.upperBound)
        let valueEnd = endRange.lowerBound

        guard valueStart < valueEnd else { return nil }

        return String(block[valueStart..<valueEnd])
    }

    /// Sign a nonce with the NKey
    public func sign(nonce: String) throws -> String {
        try authenticator.sign(nonce: nonce)
    }

    /// Get the public key
    public var publicKey: String {
        authenticator.publicKey
    }
}

/// Credentials-related errors
public enum CredentialsError: Error, Sendable {
    case invalidFormat
    case fileNotFound(String)
    case readError(String)
}

extension CredentialsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidFormat:
            return "Invalid credentials file format"
        case .fileNotFound(let path):
            return "Credentials file not found: \(path)"
        case .readError(let reason):
            return "Error reading credentials: \(reason)"
        }
    }
}
