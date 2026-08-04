// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// A dedicated `nats-server` process under test control, so a test can drop
/// and restore the connection on demand.
final class NatsServerProcess {
    let port: Int
    private let binaryPath: String
    private let storeDirectory: String?
    private var process: Process?

    private init(port: Int, binaryPath: String, storeDirectory: String?) {
        self.port = port
        self.binaryPath = binaryPath
        self.storeDirectory = storeDirectory
    }

    /// Locate the `nats-server` binary and start it. Returns `nil` when the
    /// binary is unavailable so the caller can skip the test.
    /// - Parameter jetStream: enable JetStream, backed by a per-server
    ///   temporary store so parallel or repeated runs cannot collide on state.
    static func startIfAvailable(port: Int, jetStream: Bool = false) -> NatsServerProcess? {
        guard let binary = locateBinary() else { return nil }
        let store = jetStream
            ? NSTemporaryDirectory() + "nats-js-\(port)-\(UUID().uuidString.prefix(8))"
            : nil
        let server = NatsServerProcess(port: port, binaryPath: binary, storeDirectory: store)
        do {
            try server.launch()
            return server
        } catch {
            return nil
        }
    }

    /// Start the server again after a `stop()` (same port).
    func restart() throws {
        try launch()
    }

    /// Terminate the server process if it is running.
    func stop() {
        guard let process = process else { return }
        defer { self.process = nil }
        guard process.isRunning else { return }

        process.terminate()

        // Deliberately NOT `waitUntilExit()`. That blocks the calling thread
        // indefinitely and depends on dispatch reaping the child — and these
        // tests are called from `defer` inside async test bodies, on the
        // cooperative pool. Under the load the write-path suites create it
        // simply never returned, wedging the whole run in a place that looked
        // nothing like the cause.
        //
        // Bounded polling instead, escalating to SIGKILL. A test server that
        // will not die politely is not worth an entire suite.
        if !waitForExit(of: process, upTo: 3.0) {
            kill(process.processIdentifier, SIGKILL)
            _ = waitForExit(of: process, upTo: 2.0)
        }
    }

    private func waitForExit(of process: Process, upTo seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !process.isRunning { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !process.isRunning
    }

    /// Stop the server and discard any JetStream state it accumulated.
    func stopAndCleanUp() {
        stop()
        if let storeDirectory {
            try? FileManager.default.removeItem(atPath: storeDirectory)
        }
    }

    private func launch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        var arguments = ["--addr", "127.0.0.1", "--port", String(port)]
        if let storeDirectory {
            arguments += ["-js", "-sd", storeDirectory]
        }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        // Give the server a brief moment to bind its listener. The client
        // connect path retries, so this only needs to be approximate.
        Thread.sleep(forTimeInterval: 0.3)
    }

    private static func locateBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/nats-server",
            "/usr/local/bin/nats-server",
            "/usr/bin/nats-server",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // Fall back to a PATH lookup via `which`.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "nats-server"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
