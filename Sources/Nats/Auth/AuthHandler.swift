// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Handles authentication for NATS connections
struct AuthHandler: Sendable {
    let config: AuthConfig

    /// Build authentication fields for CONNECT message
    func buildAuthFields(nonce: String?) throws -> AuthFields {
        switch config {
        case .none:
            return AuthFields()

        case .token(let token):
            return AuthFields(authToken: token)

        case .userPass(let user, let password):
            return AuthFields(user: user, pass: password)

        case .nkey(let seed):
            let authenticator = try NKeyAuthenticator(seed: seed)
            let sig: String?
            if let nonce = nonce {
                sig = try authenticator.sign(nonce: nonce)
            } else {
                sig = nil
            }
            return AuthFields(nkey: authenticator.publicKey, sig: sig)

        case .credentials(let url):
            let credentials = try JWTCredentials.load(from: url)
            let sig: String?
            if let nonce = nonce {
                sig = try credentials.sign(nonce: nonce)
            } else {
                sig = nil
            }
            return AuthFields(jwt: credentials.jwt, nkey: credentials.publicKey, sig: sig)

        case .jwt(let jwt, let nkeySeed):
            let credentials = try JWTCredentials(jwt: jwt, nkeySeed: nkeySeed)
            let sig: String?
            if let nonce = nonce {
                sig = try credentials.sign(nonce: nonce)
            } else {
                sig = nil
            }
            return AuthFields(jwt: jwt, nkey: credentials.publicKey, sig: sig)
        }
    }
}

/// Authentication fields for CONNECT message
struct AuthFields: Sendable {
    let authToken: String?
    let user: String?
    let pass: String?
    let jwt: String?
    let nkey: String?
    let sig: String?

    init(
        authToken: String? = nil,
        user: String? = nil,
        pass: String? = nil,
        jwt: String? = nil,
        nkey: String? = nil,
        sig: String? = nil
    ) {
        self.authToken = authToken
        self.user = user
        self.pass = pass
        self.jwt = jwt
        self.nkey = nkey
        self.sig = sig
    }
}
