// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Holds a value produced by another task, readable without awaiting that task.
final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    func set(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        if stored == nil { stored = value }
    }

    var value: T? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// Runs `body` in its own task and waits up to `limit` for a result, returning
/// nil if none arrives.
///
/// **Use this instead of awaiting the task.** Two Swift facts make the obvious
/// approach wrong for anything testing a deadline:
///
/// - `await task.value` / `.result` is not cancellation-responsive. Cancelling
///   the waiter does not resume it; it waits for the future regardless.
/// - swift-testing's `.timeLimit` trait is delivered *as cancellation*, so it
///   cannot rescue a test that is stuck on exactly the class of bug under test.
///
/// Together those mean a test that awaits a hung operation hangs the whole test
/// target rather than failing — which is how these defects stayed invisible.
/// Polling a box keeps a regression to a bounded failure.
func boundedly<T: Sendable>(
    _ limit: Duration = .seconds(5),
    _ body: @escaping @Sendable () async -> T
) async -> T? {
    let box = ResultBox<T>()
    let task = Task { box.set(await body()) }
    defer { task.cancel() }

    let deadline = ContinuousClock().now.advanced(by: limit)
    while ContinuousClock().now < deadline {
        if let value = box.value { return value }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return box.value
}

/// Flattened outcome of an operation under test, so it can cross a `ResultBox`
/// without carrying a non-Sendable error.
enum OperationOutcome: Equatable, Sendable {
    case succeeded
    case failed(String)

    init(catching body: () async throws -> Void) async {
        do {
            try await body()
            self = .succeeded
        } catch {
            self = .failed("\(error)")
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var message: String? {
        if case .failed(let m) = self { return m }
        return nil
    }
}
