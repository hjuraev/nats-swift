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
    public static func validateForPublish(_ subject: String) throws(ProtocolError) {
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

        // No wildcards allowed for publishing
        guard !subject.contains("*") && !subject.contains(">") else {
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

    /// Generate a unique inbox subject
    public static func newInbox(prefix: String = "_INBOX") -> String {
        let random = (0..<22).map { _ in
            let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
            return chars.randomElement()!
        }
        return "\(prefix).\(String(random))"
    }
}
