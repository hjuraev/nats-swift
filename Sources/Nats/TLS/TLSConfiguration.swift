// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import NIOSSL

/// TLS configuration for NATS connections
public struct TLSConfig: Sendable {
    /// Whether TLS is enabled
    public var enabled: Bool

    /// Certificate verification mode
    public var certificateVerification: CertificateVerification

    /// Trust roots for certificate validation
    public var trustRoots: NIOSSLTrustRoots

    /// Client certificate chain for mTLS
    public var certificateChain: [NIOSSLCertificateSource]

    /// Client private key for mTLS
    public var privateKey: NIOSSLPrivateKeySource?

    /// Minimum TLS protocol version
    public var minimumTLSVersion: TLSVersion

    /// Server hostname for SNI and certificate validation
    public var serverHostname: String?

    public init(
        enabled: Bool = false,
        certificateVerification: CertificateVerification = .fullVerification,
        trustRoots: NIOSSLTrustRoots = .default,
        certificateChain: [NIOSSLCertificateSource] = [],
        privateKey: NIOSSLPrivateKeySource? = nil,
        minimumTLSVersion: TLSVersion = .tlsv12,
        serverHostname: String? = nil
    ) {
        self.enabled = enabled
        self.certificateVerification = certificateVerification
        self.trustRoots = trustRoots
        self.certificateChain = certificateChain
        self.privateKey = privateKey
        self.minimumTLSVersion = minimumTLSVersion
        self.serverHostname = serverHostname
    }

    /// Create TLS configuration with custom CA certificate
    public static func withCustomCA(
        certificatePath: String,
        minimumTLSVersion: TLSVersion = .tlsv12
    ) throws -> TLSConfig {
        let certificates = try NIOSSLCertificate.fromPEMFile(certificatePath)
        return TLSConfig(
            enabled: true,
            trustRoots: .certificates(certificates),
            minimumTLSVersion: minimumTLSVersion
        )
    }

    /// Create TLS configuration for mTLS (mutual TLS)
    public static func mTLS(
        certificateChainPath: String,
        privateKeyPath: String,
        trustRootsPath: String? = nil,
        minimumTLSVersion: TLSVersion = .tlsv12
    ) throws -> TLSConfig {
        let trustRoots: NIOSSLTrustRoots
        if let trustPath = trustRootsPath {
            let caCerts = try NIOSSLCertificate.fromPEMFile(trustPath)
            trustRoots = .certificates(caCerts)
        } else {
            trustRoots = .default
        }

        // Load certificate chain
        let certificates = try NIOSSLCertificate.fromPEMFile(certificateChainPath)
        let certificateChain = certificates.map { NIOSSLCertificateSource.certificate($0) }

        // Load private key
        let privateKey = try NIOSSLPrivateKey(file: privateKeyPath, format: .pem)

        return TLSConfig(
            enabled: true,
            trustRoots: trustRoots,
            certificateChain: certificateChain,
            privateKey: .privateKey(privateKey),
            minimumTLSVersion: minimumTLSVersion
        )
    }

    /// Create NIO SSL client configuration
    func makeSSLContext() throws -> NIOSSLContext {
        var config = TLSConfiguration.makeClientConfiguration()
        config.minimumTLSVersion = minimumTLSVersion
        config.certificateVerification = certificateVerification
        config.trustRoots = trustRoots

        if !certificateChain.isEmpty {
            config.certificateChain = certificateChain
        }

        if let privateKey = privateKey {
            config.privateKey = privateKey
        }

        return try NIOSSLContext(configuration: config)
    }
}

// MARK: - Convenience Extensions

extension TLSConfig {
    /// Simple TLS with default settings
    public static var enabled: TLSConfig {
        TLSConfig(enabled: true)
    }

    /// Insecure TLS (no certificate verification) - USE ONLY FOR TESTING
    public static var insecure: TLSConfig {
        TLSConfig(
            enabled: true,
            certificateVerification: .none
        )
    }
}
