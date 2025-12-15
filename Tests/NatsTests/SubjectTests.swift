// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Nats

@Suite("Subject Validation Tests")
struct SubjectTests {

    @Test("Valid publish subjects")
    func validPublishSubjects() throws {
        let validSubjects = [
            "foo",
            "foo.bar",
            "foo.bar.baz",
            "FOO",
            "foo-bar",
            "foo_bar",
            "foo123",
        ]

        for subject in validSubjects {
            try Subject.validateForPublish(subject)
        }
    }

    @Test("Invalid publish subjects")
    func invalidPublishSubjects() {
        let invalidSubjects = [
            "",           // Empty
            " ",          // Space only
            "foo bar",    // Contains space
            "foo\tbar",   // Contains tab
            ".foo",       // Starts with dot
            "foo.",       // Ends with dot
            "foo..bar",   // Empty token
            "foo.*.bar",  // Contains wildcard
            "foo.>",      // Contains wildcard
        ]

        for subject in invalidSubjects {
            #expect(throws: ProtocolError.self) {
                try Subject.validateForPublish(subject)
            }
        }
    }

    @Test("Valid subscribe subjects")
    func validSubscribeSubjects() throws {
        let validSubjects = [
            "foo",
            "foo.bar",
            "*",
            "foo.*",
            "*.bar",
            "foo.*.bar",
            ">",
            "foo.>",
            "foo.bar.>",
        ]

        for subject in validSubjects {
            try Subject.validateForSubscribe(subject)
        }
    }

    @Test("Invalid subscribe subjects")
    func invalidSubscribeSubjects() {
        let invalidSubjects = [
            "",             // Empty
            "foo.>.bar",    // > not at end
            "foo*",         // * not full token
            "foo>",         // > not full token
        ]

        for subject in invalidSubjects {
            #expect(throws: ProtocolError.self) {
                try Subject.validateForSubscribe(subject)
            }
        }
    }

    @Test("Subject matching")
    func subjectMatching() {
        // Exact matches
        #expect(Subject.matches(subject: "foo", pattern: "foo"))
        #expect(!Subject.matches(subject: "foo", pattern: "bar"))

        // Single wildcard
        #expect(Subject.matches(subject: "foo.bar", pattern: "foo.*"))
        #expect(Subject.matches(subject: "foo.baz", pattern: "foo.*"))
        #expect(!Subject.matches(subject: "foo.bar.baz", pattern: "foo.*"))

        // Multi-level wildcard
        #expect(Subject.matches(subject: "foo.bar", pattern: "foo.>"))
        #expect(Subject.matches(subject: "foo.bar.baz", pattern: "foo.>"))
        #expect(Subject.matches(subject: "foo", pattern: ">"))

        // Mixed
        #expect(Subject.matches(subject: "foo.bar.baz", pattern: "foo.*.baz"))
        #expect(!Subject.matches(subject: "foo.bar.qux", pattern: "foo.*.baz"))
    }

    @Test("Inbox generation")
    func inboxGeneration() {
        let inbox1 = Subject.newInbox()
        let inbox2 = Subject.newInbox()

        #expect(inbox1.hasPrefix("_INBOX."))
        #expect(inbox2.hasPrefix("_INBOX."))
        #expect(inbox1 != inbox2)

        let customInbox = Subject.newInbox(prefix: "_MY_INBOX")
        #expect(customInbox.hasPrefix("_MY_INBOX."))
    }
}
