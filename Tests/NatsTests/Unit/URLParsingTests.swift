// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
import Foundation
@testable import Nats

@Suite("URL Parsing Tests")
struct URLParsingTests {

    // MARK: - Single URL Parsing

    @Test("Parse URL with user and password extracts userPass auth")
    func parseURLWithUserPassword() throws {
        var options = NatsClientOptions()
        try options.url("nats://myuser:mypassword@localhost:4222")

        if case .userPass(let user, let password) = options.auth {
            #expect(user == "myuser")
            #expect(password == "mypassword")
        } else {
            Issue.record("Expected userPass auth but got \(options.auth)")
        }
    }

    @Test("Parse URL with user only extracts token auth")
    func parseURLWithUserOnly() throws {
        var options = NatsClientOptions()
        try options.url("nats://mytoken@localhost:4222")

        if case .token(let token) = options.auth {
            #expect(token == "mytoken")
        } else {
            Issue.record("Expected token auth but got \(options.auth)")
        }
    }

    @Test("Parse URL without credentials keeps auth as none")
    func parseURLWithoutCredentials() throws {
        var options = NatsClientOptions()
        try options.url("nats://localhost:4222")

        if case .none = options.auth {
            // Expected
        } else {
            Issue.record("Expected no auth but got \(options.auth)")
        }
    }

    @Test("Stored URL does not contain credentials")
    func storedURLHasNoCredentials() throws {
        var options = NatsClientOptions()
        try options.url("nats://secret_user:secret_pass@10.3.30.6:4222")

        #expect(options.servers.count == 1)
        let storedURL = options.servers[0]

        // URL should not contain user or password
        #expect(storedURL.user == nil)
        #expect(storedURL.password == nil)

        // URL string should not contain credentials
        let urlString = storedURL.absoluteString
        #expect(!urlString.contains("secret_user"))
        #expect(!urlString.contains("secret_pass"))

        // Host and port should be preserved
        #expect(storedURL.host == "10.3.30.6")
        #expect(storedURL.port == 4222)
    }

    @Test("Parse TLS URL with credentials")
    func parseTLSURLWithCredentials() throws {
        var options = NatsClientOptions()
        try options.url("tls://user:pass@secure.nats.io:4443")

        #expect(options.tls.enabled == true)

        if case .userPass(let user, let password) = options.auth {
            #expect(user == "user")
            #expect(password == "pass")
        } else {
            Issue.record("Expected userPass auth")
        }

        #expect(options.servers[0].host == "secure.nats.io")
        #expect(options.servers[0].port == 4443)
    }

    // MARK: - Multiple URL Parsing

    @Test("Parse multiple URLs extracts auth from first with credentials")
    func parseMultipleURLsExtractsAuthFromFirst() throws {
        var options = NatsClientOptions()
        try options.urls([
            "nats://localhost:4222",
            "nats://admin:secret@backup.nats.io:4222",
            "nats://other:pass@third.nats.io:4222"
        ])

        // Auth should be extracted from the second URL (first with credentials)
        if case .userPass(let user, let password) = options.auth {
            #expect(user == "admin")
            #expect(password == "secret")
        } else {
            Issue.record("Expected userPass auth but got \(options.auth)")
        }

        // All URLs should be stored without credentials
        #expect(options.servers.count == 3)
        for url in options.servers {
            #expect(url.user == nil)
            #expect(url.password == nil)
        }
    }

    @Test("Parse multiple URLs without credentials")
    func parseMultipleURLsWithoutCredentials() throws {
        var options = NatsClientOptions()
        try options.urls([
            "nats://server1:4222",
            "nats://server2:4222"
        ])

        if case .none = options.auth {
            // Expected
        } else {
            Issue.record("Expected no auth")
        }

        #expect(options.servers.count == 2)
    }

    @Test("Parse multiple URLs strips credentials from all")
    func parseMultipleURLsStripsAllCredentials() throws {
        var options = NatsClientOptions()
        try options.urls([
            "nats://user1:pass1@server1:4222",
            "nats://user2:pass2@server2:4222"
        ])

        // Only first URL's credentials should be used
        if case .userPass(let user, let password) = options.auth {
            #expect(user == "user1")
            #expect(password == "pass1")
        } else {
            Issue.record("Expected userPass auth")
        }

        // All URLs should have credentials stripped
        for (index, url) in options.servers.enumerated() {
            #expect(url.user == nil, "URL at index \(index) should not have user")
            #expect(url.password == nil, "URL at index \(index) should not have password")
        }
    }

    // MARK: - URL Sanitization

    @Test("sanitizedDescription removes credentials")
    func sanitizedDescriptionRemovesCredentials() {
        let url = URL(string: "nats://user:password@localhost:4222")!
        let sanitized = url.sanitizedDescription

        #expect(!sanitized.contains("user"))
        #expect(!sanitized.contains("password"))
        #expect(sanitized.contains("localhost"))
        #expect(sanitized.contains("4222"))
    }

    @Test("sanitizedDescription preserves URL without credentials")
    func sanitizedDescriptionPreservesCleanURL() {
        let url = URL(string: "nats://localhost:4222")!
        let sanitized = url.sanitizedDescription

        #expect(sanitized == "nats://localhost:4222")
    }

    @Test("strippingCredentials returns URL without credentials")
    func strippingCredentialsWorks() {
        let url = URL(string: "nats://secret:hunter2@myserver.com:4222")!
        let stripped = url.strippingCredentials()

        #expect(stripped.user == nil)
        #expect(stripped.password == nil)
        #expect(stripped.host == "myserver.com")
        #expect(stripped.port == 4222)
        #expect(stripped.scheme == "nats")
    }

    @Test("strippingCredentials preserves clean URL")
    func strippingCredentialsPreservesCleanURL() {
        let url = URL(string: "nats://localhost:4222")!
        let stripped = url.strippingCredentials()

        #expect(stripped.absoluteString == url.absoluteString)
    }

    // MARK: - Edge Cases

    @Test("Parse URL with special characters in password")
    func parseURLWithSpecialCharsInPassword() throws {
        // URL-encoded special characters - Swift URL keeps them percent-encoded
        var options = NatsClientOptions()
        try options.url("nats://user:p%40ss%3Aw0rd@localhost:4222")

        if case .userPass(let user, let password) = options.auth {
            #expect(user == "user")
            // Swift's URL.password returns percent-encoded string
            #expect(password == "p%40ss%3Aw0rd")
        } else {
            Issue.record("Expected userPass auth")
        }
    }

    @Test("Parse URL with IP address")
    func parseURLWithIPAddress() throws {
        var options = NatsClientOptions()
        try options.url("nats://internal_user:JT6feBeXgAm5YV22@10.3.30.6")

        if case .userPass(let user, let password) = options.auth {
            #expect(user == "internal_user")
            #expect(password == "JT6feBeXgAm5YV22")
        } else {
            Issue.record("Expected userPass auth")
        }

        #expect(options.servers[0].host == "10.3.30.6")
        #expect(options.servers[0].user == nil)
        #expect(options.servers[0].password == nil)
    }

    @Test("Invalid URL throws error")
    func invalidURLThrows() {
        var options = NatsClientOptions()

        // URL with invalid characters that Swift's URL initializer will reject
        #expect(throws: ConnectionError.self) {
            try options.url("nats://host with spaces:4222")
        }
    }
}
