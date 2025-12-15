// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Nats

@Suite("NatsHeaders Tests")
struct HeadersTests {

    @Test("Basic header operations")
    func basicOperations() {
        var headers = NatsHeaders()

        // Set and get
        headers["Content-Type"] = "application/json"
        #expect(headers["Content-Type"] == "application/json")
        #expect(headers["content-type"] == "application/json")  // Case insensitive

        // Update
        headers["Content-Type"] = "text/plain"
        #expect(headers["Content-Type"] == "text/plain")

        // Remove
        headers["Content-Type"] = nil
        #expect(headers["Content-Type"] == nil)
    }

    @Test("Multiple values for same key")
    func multipleValues() {
        var headers = NatsHeaders()

        headers.append("Accept", "application/json")
        headers.append("Accept", "text/plain")

        let values = headers.values(for: "Accept")
        #expect(values.count == 2)
        #expect(values.contains("application/json"))
        #expect(values.contains("text/plain"))

        // First value via subscript
        #expect(headers["Accept"] == "application/json")
    }

    @Test("Dictionary literal initialization")
    func dictionaryLiteral() {
        let headers: NatsHeaders = [
            "X-Custom-Header": "value1",
            "X-Another-Header": "value2"
        ]

        #expect(headers["X-Custom-Header"] == "value1")
        #expect(headers["X-Another-Header"] == "value2")
    }

    @Test("Contains check")
    func containsKey() {
        let headers: NatsHeaders = ["X-Test": "value"]

        #expect(headers.contains("X-Test"))
        #expect(headers.contains("x-test"))  // Case insensitive
        #expect(!headers.contains("X-Missing"))
    }

    @Test("Keys enumeration")
    func keysEnumeration() {
        var headers = NatsHeaders()
        headers["A"] = "1"
        headers["B"] = "2"
        headers.append("A", "3")  // Duplicate

        let keys = headers.keys
        #expect(keys.count == 2)
        #expect(keys.contains("A"))
        #expect(keys.contains("B"))
    }

    @Test("Status headers")
    func statusHeaders() {
        var headers = NatsHeaders()

        // No status
        #expect(headers.status == nil)
        #expect(!headers.isNoMessages)
        #expect(!headers.isTimeout)
        #expect(!headers.isNoResponders)

        // 404 - No messages
        headers[NatsHeaders.Keys.status] = "404"
        #expect(headers.status == 404)
        #expect(headers.isNoMessages)

        // 408 - Timeout
        headers[NatsHeaders.Keys.status] = "408"
        #expect(headers.isTimeout)

        // 503 - No responders
        headers[NatsHeaders.Keys.status] = "503"
        #expect(headers.isNoResponders)
    }

    @Test("Iteration")
    func iteration() {
        let headers: NatsHeaders = [
            "Key1": "Value1",
            "Key2": "Value2"
        ]

        var count = 0
        for (key, value) in headers {
            #expect(!key.isEmpty)
            #expect(!value.isEmpty)
            count += 1
        }
        #expect(count == 2)
    }

    @Test("Empty check")
    func emptyCheck() {
        let empty = NatsHeaders()
        #expect(empty.isEmpty)
        #expect(empty.count == 0)

        let nonEmpty: NatsHeaders = ["Key": "Value"]
        #expect(!nonEmpty.isEmpty)
        #expect(nonEmpty.count == 1)
    }
}
