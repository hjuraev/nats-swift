// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Utilities for NATS subject validation and manipulation
public enum Subject {
    /// Maximum subject length
    public static let maxLength = 256

    /// Wildcard token that matches a single token
    public static let tokenWildcard = "*"

    /// Wildcard token that matches one or more tokens
    public static let fullWildcard = ">"

    /// Token separator
    public static let separator: Character = "."

    /// Validate a subject for publishing (no wildcards allowed)
    ///
    /// Runs on every publish and request, so it reads the UTF-8 bytes once
    /// instead of making a grapheme-aware pass per rule (`count`, several
    /// `contains`). Rules, and which error a subject breaking several of them
    /// gets, are unchanged.
    public static func validateForPublish(_ subject: String) throws(ProtocolError) {
        let utf8 = subject.utf8
        guard let first = utf8.first, let last = utf8.last else {
            throw .invalidSubject("Subject cannot be empty")
        }

        // Characters never outnumber bytes, so the character count is only
        // needed when the byte count is over the limit.
        guard utf8.count <= maxLength || subject.count <= maxLength else {
            throw .invalidSubject("Subject exceeds maximum length of \(maxLength)")
        }

        var hasSpace = false
        var hasTab = false
        var hasEmptyToken = false
        var hasWildcard = false
        var previous: UInt8 = 0
        for byte in utf8 {
            switch byte {
            case UInt8(ascii: " "): hasSpace = true
            case UInt8(ascii: "\t"): hasTab = true
            case UInt8(ascii: "."): if previous == UInt8(ascii: ".") { hasEmptyToken = true }
            case UInt8(ascii: "*"), UInt8(ascii: ">"): hasWildcard = true
            default: break
            }
            previous = byte
        }

        guard !hasSpace else {
            throw .invalidSubject("Subject cannot contain spaces")
        }
        guard !hasTab else {
            throw .invalidSubject("Subject cannot contain tabs")
        }
        guard first != UInt8(ascii: "."), last != UInt8(ascii: ".") else {
            throw .invalidSubject("Subject cannot start or end with a dot")
        }
        guard !hasEmptyToken else {
            throw .invalidSubject("Subject cannot contain empty tokens")
        }
        // No wildcards allowed for publishing
        guard !hasWildcard else {
            throw .invalidSubject("Wildcards not allowed in publish subject")
        }
    }

    /// Validate a subject for subscribing (wildcards allowed)
    public static func validateForSubscribe(_ subject: String) throws(ProtocolError) {
        guard !subject.isEmpty else {
            throw .invalidSubject("Subject cannot be empty")
        }

        guard subject.count <= maxLength else {
            throw .invalidSubject("Subject exceeds maximum length of \(maxLength)")
        }

        guard !subject.contains(" ") else {
            throw .invalidSubject("Subject cannot contain spaces")
        }

        guard !subject.contains("\t") else {
            throw .invalidSubject("Subject cannot contain tabs")
        }

        guard !subject.hasPrefix(".") && !subject.hasSuffix(".") else {
            throw .invalidSubject("Subject cannot start or end with a dot")
        }

        guard !subject.contains("..") else {
            throw .invalidSubject("Subject cannot contain empty tokens")
        }

        // Validate wildcard usage
        let tokens = subject.split(separator: separator, omittingEmptySubsequences: false)
        for (index, token) in tokens.enumerated() {
            let tokenStr = String(token)

            // ">" must be the last token
            if tokenStr.contains(">") {
                if index != tokens.count - 1 {
                    throw .invalidSubject("'>' wildcard must be the last token")
                }
                if tokenStr != ">" {
                    throw .invalidSubject("'>' must be a complete token")
                }
            }

            // "*" must be a complete token
            if tokenStr.contains("*") && tokenStr != "*" {
                throw .invalidSubject("'*' must be a complete token")
            }
        }
    }

    /// Check if a subject matches a subscription pattern
    public static func matches(subject: String, pattern: String) -> Bool {
        let subjectTokens = subject.split(separator: separator, omittingEmptySubsequences: false)
        let patternTokens = pattern.split(separator: separator, omittingEmptySubsequences: false)

        var subjectIndex = 0
        var patternIndex = 0

        while patternIndex < patternTokens.count {
            let patternToken = String(patternTokens[patternIndex])

            // ">" matches everything remaining
            if patternToken == fullWildcard {
                return true
            }

            // No more subject tokens but pattern expects more
            if subjectIndex >= subjectTokens.count {
                return false
            }

            let subjectToken = String(subjectTokens[subjectIndex])

            // "*" matches any single token
            if patternToken == tokenWildcard {
                subjectIndex += 1
                patternIndex += 1
                continue
            }

            // Exact match required
            if patternToken != subjectToken {
                return false
            }

            subjectIndex += 1
            patternIndex += 1
        }

        // Must have consumed all subject tokens
        return subjectIndex == subjectTokens.count
    }

    /// Generate a random token of the given length
    public static func randomToken(length: Int = 22) -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    /// Generate a unique inbox subject
    public static func newInbox(prefix: String = "_INBOX") -> String {
        return "\(prefix).\(randomToken())"
    }
}
