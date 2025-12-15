// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import XCTest

import NATS_SwiftTests

var tests = [XCTestCaseEntry]()
tests += NATS_SwiftTests.allTests()
XCTMain(tests)