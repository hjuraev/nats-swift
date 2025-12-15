// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
@preconcurrency import Crypto

/// NKey authentication using Ed25519 signatures
public struct NKeyAuthenticator: @unchecked Sendable {
    /// The NKey seed (starts with 'S')
    private let seed: String

    /// The private key derived from the seed
    private let privateKey: Curve25519.Signing.PrivateKey

    /// The public key
    public let publicKey: String

    /// NKey prefix bytes
    private enum Prefix: UInt8 {
        case seed = 18          // 'S'
        case privateKey = 15    // 'P'
        case server = 13        // 'N'
        case cluster = 2        // 'C'
        case operator_ = 14     // 'O'
        case account = 0        // 'A'
        case user = 20          // 'U'
    }

    /// Initialize with an NKey seed
    public init(seed: String) throws {
        guard seed.hasPrefix("S") else {
            throw NKeyError.invalidSeed("Seed must start with 'S'")
        }

        self.seed = seed

        // Decode the seed from base32
        let decoded = try Self.base32Decode(seed)

        // Validate checksum
        guard decoded.count >= 4 else {
            throw NKeyError.invalidSeed("Seed too short")
        }

        let payload = Array(decoded.dropLast(2))
        let checksum = Array(decoded.suffix(2))

        let calculatedChecksum = Self.crc16(payload)
        guard checksum == calculatedChecksum else {
            throw NKeyError.invalidSeed("Invalid checksum")
        }

        // Extract the raw seed (skip prefix bytes)
        guard payload.count >= 34 else {
            throw NKeyError.invalidSeed("Invalid seed length")
        }

        let rawSeed = Array(payload[2..<34])

        // Create Ed25519 private key from seed
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(rawSeed))

        // Generate public key string
        let publicKeyBytes = [UInt8](privateKey.publicKey.rawRepresentation)
        self.publicKey = try Self.encodePublicKey(publicKeyBytes, prefix: .user)
    }

    /// Sign a nonce and return the base64-encoded signature
    public func sign(nonce: String) throws -> String {
        guard let nonceData = nonce.data(using: .utf8) else {
            throw NKeyError.invalidNonce
        }

        let signature = try privateKey.signature(for: nonceData)
        return Data(signature).base64EncodedString()
    }

    /// Sign raw data
    public func sign(data: Data) throws -> Data {
        Data(try privateKey.signature(for: data))
    }

    // MARK: - Base32 Encoding/Decoding

    private static let base32Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    private static func base32Decode(_ string: String) throws -> [UInt8] {
        let chars = Array(string.uppercased())
        var result: [UInt8] = []
        var buffer: UInt64 = 0
        var bitsLeft = 0

        for char in chars {
            guard let index = base32Alphabet.firstIndex(of: char) else {
                if char == "=" { continue }  // Padding
                throw NKeyError.invalidSeed("Invalid base32 character: \(char)")
            }

            let value = base32Alphabet.distance(from: base32Alphabet.startIndex, to: index)
            buffer = (buffer << 5) | UInt64(value)
            bitsLeft += 5

            if bitsLeft >= 8 {
                bitsLeft -= 8
                result.append(UInt8((buffer >> bitsLeft) & 0xFF))
            }
        }

        return result
    }

    private static func base32Encode(_ bytes: [UInt8]) -> String {
        var result = ""
        var buffer: UInt64 = 0
        var bitsLeft = 0

        for byte in bytes {
            buffer = (buffer << 8) | UInt64(byte)
            bitsLeft += 8

            while bitsLeft >= 5 {
                bitsLeft -= 5
                let index = Int((buffer >> bitsLeft) & 0x1F)
                result.append(base32Alphabet[base32Alphabet.index(base32Alphabet.startIndex, offsetBy: index)])
            }
        }

        if bitsLeft > 0 {
            let index = Int((buffer << (5 - bitsLeft)) & 0x1F)
            result.append(base32Alphabet[base32Alphabet.index(base32Alphabet.startIndex, offsetBy: index)])
        }

        return result
    }

    private static func encodePublicKey(_ publicKey: [UInt8], prefix: Prefix) throws -> String {
        var payload: [UInt8] = [prefix.rawValue]
        payload.append(contentsOf: publicKey)

        let checksum = crc16(payload)
        payload.append(contentsOf: checksum)

        return base32Encode(payload)
    }

    // MARK: - CRC16

    private static func crc16(_ data: [UInt8]) -> [UInt8] {
        var crc: UInt16 = 0

        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }

        return [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF)]
    }
}

/// NKey-related errors
public enum NKeyError: Error, Sendable {
    case invalidSeed(String)
    case invalidNonce
    case signingFailed(String)
}

extension NKeyError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidSeed(let reason):
            return "Invalid NKey seed: \(reason)"
        case .invalidNonce:
            return "Invalid nonce for signing"
        case .signingFailed(let reason):
            return "Signing failed: \(reason)"
        }
    }
}
