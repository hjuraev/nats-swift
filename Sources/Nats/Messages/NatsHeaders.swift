// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// NATS message headers
public struct NatsHeaders: Sendable, Equatable {
    /// Internal storage for headers (allows duplicate keys)
    private var storage: [(String, String)]

    /// Header version prefix
    public static let version = "NATS/1.0"

    // Well-known header keys
    public enum Keys {
        public static let msgId = "Nats-Msg-Id"
        public static let expectedStream = "Nats-Expected-Stream"
        public static let expectedLastMsgId = "Nats-Expected-Last-Msg-Id"
        public static let expectedLastSequence = "Nats-Expected-Last-Sequence"
        public static let expectedLastSubjectSequence = "Nats-Expected-Last-Subject-Sequence"
        public static let lastConsumer = "Nats-Last-Consumer"
        public static let lastStream = "Nats-Last-Stream"
        public static let status = "Status"
        public static let description = "Description"

        // Key-Value store headers
        public static let kvOperation = "KV-Operation"
        public static let rollup = "Nats-Rollup"
        public static let natsStream = "Nats-Stream"
        public static let natsSequence = "Nats-Sequence"
        public static let natsTimeStamp = "Nats-Time-Stamp"
        public static let natsSubject = "Nats-Subject"
        public static let natsLastSequence = "Nats-Last-Sequence"
        public static let natsMarkerReason = "Nats-Marker-Reason"
    }

    /// Create empty headers
    public init() {
        self.storage = []
    }

    /// Create headers from key-value pairs
    public init(_ pairs: [(String, String)]) {
        self.storage = pairs
    }

    /// Create headers from a dictionary (single value per key)
    public init(_ dictionary: [String: String]) {
        self.storage = dictionary.map { ($0.key, $0.value) }
    }

    // MARK: - Access

    /// Case-insensitive header name comparison without allocating.
    ///
    /// Header names are ASCII on the wire, and every lookup used to lowercase
    /// both names — two string allocations per comparison, on every message
    /// whose status or KV operation was read. Falls back to `lowercased()`
    /// only for non-ASCII names.
    static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        var left = lhs.utf8.makeIterator()
        var right = rhs.utf8.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil):
                return true
            case (let l?, let r?):
                if l == r { continue }
                if l >= 0x80 || r >= 0x80 {
                    return lhs.lowercased() == rhs.lowercased()
                }
                let foldedL = (l >= 0x41 && l <= 0x5A) ? l | 0x20 : l
                let foldedR = (r >= 0x41 && r <= 0x5A) ? r | 0x20 : r
                if foldedL != foldedR { return false }
            default:
                // Different lengths: unequal for ASCII, but lowercasing can
                // change the length of other scripts.
                return lhs.utf8.contains(where: { $0 >= 0x80 }) || rhs.utf8.contains(where: { $0 >= 0x80 })
                    ? lhs.lowercased() == rhs.lowercased()
                    : false
            }
        }
    }

    /// Get the first value for a header key (case-insensitive)
    public subscript(_ key: String) -> String? {
        get {
            storage.first { Self.namesMatch($0.0, key) }?.1
        }
        set {
            // Remove existing values for this key
            storage.removeAll { Self.namesMatch($0.0, key) }
            // Add new value if provided
            if let value = newValue {
                storage.append((key, value))
            }
        }
    }

    /// Get all values for a header key (case-insensitive)
    public func values(for key: String) -> [String] {
        storage
            .filter { Self.namesMatch($0.0, key) }
            .map(\.1)
    }

    /// Append a value for a header key (allows duplicates)
    public mutating func append(_ key: String, _ value: String) {
        storage.append((key, value))
    }

    /// Check if headers contain a key
    public func contains(_ key: String) -> Bool {
        storage.contains { Self.namesMatch($0.0, key) }
    }

    /// Remove all values for a key
    public mutating func removeAll(for key: String) {
        storage.removeAll { Self.namesMatch($0.0, key) }
    }

    /// Get all header keys (unique)
    public var keys: [String] {
        var seen = Set<String>()
        return storage.compactMap { key, _ in
            let lower = key.lowercased()
            if seen.contains(lower) {
                return nil
            }
            seen.insert(lower)
            return key
        }
    }

    /// Check if headers are empty
    public var isEmpty: Bool {
        storage.isEmpty
    }

    /// Number of header entries (including duplicates)
    public var count: Int {
        storage.count
    }

    // MARK: - Status Header (for JetStream)

    /// Get status code from headers (used by JetStream)
    public var status: Int? {
        guard let statusStr = self[Keys.status] else { return nil }
        return Int(statusStr)
    }

    /// Get description from headers (used by JetStream)
    public var statusDescription: String? {
        self[Keys.description]
    }

    /// Check if this is a "no messages" response
    public var isNoMessages: Bool {
        status == 404
    }

    /// Check if this is a timeout response
    public var isTimeout: Bool {
        status == 408
    }

    /// Check if this is a "no responders" response
    public var isNoResponders: Bool {
        status == 503
    }
}

// MARK: - Sequence Conformance

extension NatsHeaders: Sequence {
    public func makeIterator() -> IndexingIterator<[(String, String)]> {
        storage.makeIterator()
    }
}

// MARK: - ExpressibleByDictionaryLiteral

extension NatsHeaders: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, String)...) {
        self.storage = elements
    }
}

// MARK: - CustomStringConvertible

extension NatsHeaders: CustomStringConvertible {
    public var description: String {
        let pairs = storage.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
        return "NatsHeaders([\(pairs)])"
    }
}

// MARK: - Equatable

extension NatsHeaders {
    public static func == (lhs: NatsHeaders, rhs: NatsHeaders) -> Bool {
        guard lhs.storage.count == rhs.storage.count else { return false }
        for (index, pair) in lhs.storage.enumerated() {
            if pair.0 != rhs.storage[index].0 || pair.1 != rhs.storage[index].1 {
                return false
            }
        }
        return true
    }
}

// MARK: - Codable

extension NatsHeaders: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let dict = try container.decode([String: String].self)
        self.storage = dict.map { ($0.key, $0.value) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // Note: This loses duplicate keys, but is needed for JSON encoding
        let dict = Dictionary(storage, uniquingKeysWith: { first, _ in first })
        try container.encode(dict)
    }
}
