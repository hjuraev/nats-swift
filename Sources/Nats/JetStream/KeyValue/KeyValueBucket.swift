// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import NIOCore

/// A handle to a Key-Value bucket backed by a JetStream stream
public actor KeyValueBucket {
    let context: JetStreamContext
    let bucket: String
    var stream: Stream

    init(context: JetStreamContext, bucket: String, stream: Stream) {
        self.context = context
        self.bucket = bucket
        self.stream = stream
    }

    // MARK: - Read Operations

    /// Get the latest value for a key. Returns nil if the key doesn't exist or is deleted/purged.
    public func get(_ key: String) async throws(JetStreamError) -> KeyValueEntry? {
        try validateKey(key)

        let streamName = "KV_\(bucket)"
        let getSubject = "$KV.\(bucket).\(key)"

        // Use Direct Get with subject shortcut
        let subject = "$JS.API.DIRECT.GET.\(streamName).\(getSubject)"

        do {
            let response = try await context.rawRequest(subject, payload: ByteBuffer())

            // Check for 404
            if let headers = response.headers, headers.isNoMessages {
                return nil
            }
            if let status = response.headers?.status, status == 404 {
                return nil
            }

            guard let entry = KeyValueEntry.fromDirectGet(response, bucket: bucket) else {
                return nil
            }

            // If the entry is a delete/purge marker, return nil
            if entry.operation == .delete || entry.operation == .purge {
                return nil
            }

            return entry
        } catch {
            // 404 from API error means key not found
            if case .apiError(let code, _, _) = error, code == 404 {
                return nil
            }
            throw error
        }
    }

    /// Get a specific revision of a key.
    public func get(_ key: String, revision: UInt64) async throws(JetStreamError) -> KeyValueEntry? {
        try validateKey(key)

        let streamName = "KV_\(bucket)"
        let subject = "$JS.API.DIRECT.GET.\(streamName)"

        let request = DirectGetRequest(seq: revision)
        let payload: ByteBuffer
        do {
            let data = try JSONEncoder().encode(request)
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            payload = buffer
        } catch {
            throw JetStreamError.kvOperationFailed(error.localizedDescription)
        }

        do {
            let response = try await context.rawRequest(subject, payload: payload)

            if let headers = response.headers, headers.isNoMessages {
                return nil
            }
            if let status = response.headers?.status, status == 404 {
                return nil
            }

            guard let entry = KeyValueEntry.fromDirectGet(response, bucket: bucket) else {
                return nil
            }

            // Verify the returned entry matches the requested key
            let expectedSubject = "$KV.\(bucket).\(key)"
            if let responseSubject = response.headers?[NatsHeaders.Keys.natsSubject],
               responseSubject != expectedSubject {
                return nil
            }

            return entry
        } catch let error as JetStreamError {
            if case .apiError(let code, _, _) = error, code == 404 {
                return nil
            }
            throw error
        }
    }

    // MARK: - Write Operations

    /// Put a value for a key, returning the revision number.
    @discardableResult
    public func put(_ key: String, value: ByteBuffer) async throws(JetStreamError) -> UInt64 {
        try validateKey(key)

        let subject = "$KV.\(bucket).\(key)"
        let ack = try await context.publish(subject, payload: value)
        return ack.seq
    }

    /// Put a string value for a key, returning the revision number.
    @discardableResult
    public func put(_ key: String, value: String) async throws(JetStreamError) -> UInt64 {
        var buffer = ByteBuffer()
        buffer.writeString(value)
        return try await put(key, value: buffer)
    }

    /// Create a key only if it does not already exist. Returns the revision.
    /// Throws `keyExists` if the key already has a value.
    @discardableResult
    public func create(_ key: String, value: ByteBuffer) async throws(JetStreamError) -> UInt64 {
        try validateKey(key)

        let subject = "$KV.\(bucket).\(key)"
        var headers = NatsHeaders()
        headers[NatsHeaders.Keys.expectedLastSubjectSequence] = "0"

        do {
            let ack = try await context.publishWithHeaders(subject, payload: value, headers: headers)
            return ack.seq
        } catch {
            // Error code 10071 = wrong last subject sequence
            if case .apiError(_, let errorCode, _) = error, errorCode == 10071 {
                // Check if existing entry is a delete/purge marker - if so, retry with that revision
                if let existing = try await getEntry(key) {
                    if existing.operation == .delete || existing.operation == .purge {
                        return try await update(key, value: value, revision: existing.revision)
                    }
                    throw JetStreamError.keyExists(key: key, revision: existing.revision)
                }
                throw JetStreamError.keyExists(key: key, revision: 0)
            }
            throw error
        }
    }

    /// Create a key with a string value only if it does not already exist.
    @discardableResult
    public func create(_ key: String, value: String) async throws(JetStreamError) -> UInt64 {
        var buffer = ByteBuffer()
        buffer.writeString(value)
        return try await create(key, value: buffer)
    }

    /// Update a key only if the current revision matches. Returns the new revision.
    @discardableResult
    public func update(_ key: String, value: ByteBuffer, revision: UInt64) async throws(JetStreamError) -> UInt64 {
        try validateKey(key)

        let subject = "$KV.\(bucket).\(key)"
        var headers = NatsHeaders()
        headers[NatsHeaders.Keys.expectedLastSubjectSequence] = String(revision)

        let ack = try await context.publishWithHeaders(subject, payload: value, headers: headers)
        return ack.seq
    }

    /// Update a key with a string value only if the current revision matches.
    @discardableResult
    public func update(_ key: String, value: String, revision: UInt64) async throws(JetStreamError) -> UInt64 {
        var buffer = ByteBuffer()
        buffer.writeString(value)
        return try await update(key, value: buffer, revision: revision)
    }

    // MARK: - Delete Operations

    /// Soft-delete a key by placing a delete marker.
    public func delete(_ key: String) async throws(JetStreamError) {
        try validateKey(key)

        let subject = "$KV.\(bucket).\(key)"
        var headers = NatsHeaders()
        headers[NatsHeaders.Keys.kvOperation] = KeyValueOperation.delete.rawValue

        _ = try await context.publishWithHeaders(subject, payload: ByteBuffer(), headers: headers)
    }

    /// Soft-delete a key with CAS (only if revision matches).
    public func delete(_ key: String, revision: UInt64) async throws(JetStreamError) {
        try validateKey(key)

        let subject = "$KV.\(bucket).\(key)"
        var headers = NatsHeaders()
        headers[NatsHeaders.Keys.kvOperation] = KeyValueOperation.delete.rawValue
        headers[NatsHeaders.Keys.expectedLastSubjectSequence] = String(revision)

        _ = try await context.publishWithHeaders(subject, payload: ByteBuffer(), headers: headers)
    }

    /// Purge a key, removing all revisions.
    public func purge(_ key: String) async throws(JetStreamError) {
        try validateKey(key)

        let subject = "$KV.\(bucket).\(key)"
        var headers = NatsHeaders()
        headers[NatsHeaders.Keys.kvOperation] = KeyValueOperation.purge.rawValue
        headers[NatsHeaders.Keys.rollup] = "sub"

        _ = try await context.publishWithHeaders(subject, payload: ByteBuffer(), headers: headers)
    }

    /// Purge a key with CAS (only if revision matches), removing all revisions.
    public func purge(_ key: String, revision: UInt64) async throws(JetStreamError) {
        try validateKey(key)

        let subject = "$KV.\(bucket).\(key)"
        var headers = NatsHeaders()
        headers[NatsHeaders.Keys.kvOperation] = KeyValueOperation.purge.rawValue
        headers[NatsHeaders.Keys.rollup] = "sub"
        headers[NatsHeaders.Keys.expectedLastSubjectSequence] = String(revision)

        _ = try await context.publishWithHeaders(subject, payload: ByteBuffer(), headers: headers)
    }

    // MARK: - Enumeration

    /// List all active keys in the bucket, optionally filtered by a subject pattern.
    ///
    /// Holds every key in memory; for large buckets prefer `keyBatches(filter:batch:)`.
    ///
    /// - Throws: `incompleteListing` when the listing ends with keys still
    ///   pending, rather than returning a partial list as if it were complete.
    public func keys(filter: String? = nil) async throws(JetStreamError) -> [String] {
        let scan = latestEntryScan(filter: filter, batch: Self.listingBatch)
        let keyPrefix = "$KV.\(bucket)."
        var keys: [String] = []
        while let messages = try await scan.next() {
            keys += KeyValueKeyBatches.activeKeys(in: messages, keyPrefix: keyPrefix)
        }
        return keys
    }

    /// The bucket's active keys, a batch at a time, fetched as the caller
    /// iterates — never more than one batch in memory.
    ///
    /// - Parameters:
    ///   - filter: key pattern, as for `keys(filter:)`.
    ///   - batch: entries fetched per round trip. Delete markers count against
    ///     it and are dropped, so a batch can hold fewer keys.
    public nonisolated func keyBatches(filter: String? = nil, batch: Int = 2048) -> KeyValueKeyBatches {
        let context = self.context
        let bucket = self.bucket
        return KeyValueKeyBatches(keyPrefix: "$KV.\(bucket).") {
            KeyValueScan(
                context: context,
                bucket: bucket,
                filterSubject: filter.map { "$KV.\(bucket).\($0)" } ?? "$KV.\(bucket).>",
                deliverPolicy: .lastPerSubject,
                headersOnly: true,
                batch: batch
            )
        }
    }

    /// Get all history entries for a key.
    ///
    /// - Throws: `incompleteListing` when the history ends with entries still pending.
    public func history(_ key: String) async throws(JetStreamError) -> [KeyValueEntry] {
        try validateKey(key)

        let scan = KeyValueScan(
            context: context,
            bucket: bucket,
            filterSubject: "$KV.\(bucket).\(key)",
            deliverPolicy: .all,
            headersOnly: false,
            batch: Self.listingBatch
        )
        var entries: [KeyValueEntry] = []
        let keyPrefix = "$KV.\(bucket)."
        while let messages = try await scan.next() {
            entries += messages.compactMap { KeyValueEntry.fromConsumerMessage($0, bucket: bucket, keyPrefix: keyPrefix) }
        }
        return entries
    }

    /// Entries per fetch for whole-bucket passes.
    private static let listingBatch = 2048

    private func latestEntryScan(filter: String?, batch: Int) -> KeyValueScan {
        KeyValueScan(
            context: context,
            bucket: bucket,
            filterSubject: filter.map { "$KV.\(bucket).\($0)" } ?? "$KV.\(bucket).>",
            deliverPolicy: .lastPerSubject,
            headersOnly: true,
            batch: batch
        )
    }

    // MARK: - Watch

    /// Watch for changes on keys matching the given pattern.
    /// Pass ">" to watch all keys.
    public func watch(
        _ keyPattern: String = ">",
        options: KeyValueWatchOptions = KeyValueWatchOptions()
    ) async throws(JetStreamError) -> KeyValueWatcher {
        try validateWatchKey(keyPattern)
        return try await KeyValueWatcher.create(
            context: context,
            bucket: bucket,
            keyPattern: keyPattern,
            options: options
        )
    }

    /// Watch all keys for changes.
    public func watchAll(
        options: KeyValueWatchOptions = KeyValueWatchOptions()
    ) async throws(JetStreamError) -> KeyValueWatcher {
        try await watch(">", options: options)
    }

    // MARK: - Maintenance

    /// Remove old delete/purge markers. Markers older than the given duration are fully purged;
    /// recent markers are kept (1 entry) to preserve tombstone semantics.
    ///
    /// Lists the bucket's latest entries to find the markers. A caller that
    /// already knows them — from its own watch — should pass them to
    /// `purgeDeletes(_:olderThan:maxConcurrent:)` and skip the listing.
    ///
    /// - Throws: `incompleteListing` if the listing ends early; nothing found
    ///   up to that point is purged.
    public func purgeDeletes(olderThan: Duration? = nil) async throws(JetStreamError) {
        let scan = latestEntryScan(filter: nil, batch: Self.listingBatch)
        var markers: [KeyValueEntry] = []
        let keyPrefix = "$KV.\(bucket)."
        while let messages = try await scan.next() {
            for message in messages {
                guard let entry = KeyValueEntry.fromConsumerMessage(message, bucket: bucket, keyPrefix: keyPrefix),
                      entry.operation != .put else { continue }
                markers.append(entry)
            }
        }
        try await purgeDeletes(markers, olderThan: olderThan)
    }

    /// Remove delete/purge markers the caller already knows about, without
    /// listing the bucket.
    ///
    /// Each purge is bounded by the marker's revision, so it cannot remove a
    /// value written after the marker: a key deleted and then put again keeps
    /// its new value. (`purge(subject:)` has no such bound; purging by subject
    /// alone from a stale view of the bucket deletes live data.)
    ///
    /// - Parameters:
    ///   - markers: entries whose `operation` is `.delete` or `.purge`, e.g.
    ///     from a watcher. Other entries are ignored.
    ///   - olderThan: markers created longer ago than this are removed with
    ///     everything before them; newer ones are kept and only the history
    ///     before them is removed. `nil` removes every marker.
    ///   - maxConcurrent: purge requests in flight at once.
    /// - Returns: the number of markers acted on.
    @discardableResult
    public func purgeDeletes(
        _ markers: [KeyValueEntry],
        olderThan: Duration? = nil,
        maxConcurrent: Int = 16
    ) async throws(JetStreamError) -> Int {
        let now = Date()
        let purges: [(subject: String, upToSequence: UInt64)] = markers.compactMap { marker in
            guard marker.operation != .put else { return nil }
            let isOld = olderThan.map { now.timeIntervalSince(marker.created) > $0.timeInterval } ?? true
            // Old: remove the marker and everything before it. Recent: keep
            // the marker, remove what came before it.
            let upToSequence = isOld ? marker.revision + 1 : marker.revision
            // A recent marker at revision 1 has no history before it.
            guard upToSequence > 1 else { return nil }
            return ("$KV.\(bucket).\(marker.key)", upToSequence)
        }
        guard !purges.isEmpty else { return 0 }

        let stream = self.stream
        let limit = max(1, maxConcurrent)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = purges.makeIterator()
                var running = 0
                while running < limit, let purge = next.next() {
                    group.addTask { _ = try await stream.purge(subject: purge.subject, upToSequence: purge.upToSequence) }
                    running += 1
                }
                while try await group.next() != nil {
                    if let purge = next.next() {
                        group.addTask { _ = try await stream.purge(subject: purge.subject, upToSequence: purge.upToSequence) }
                    }
                }
            }
        } catch let error as JetStreamError {
            throw error
        } catch {
            throw JetStreamError.mapping(error, operation: "purgeDeletes", timeout: .zero)
        }
        return purges.count
    }

    /// Get the current status of this bucket.
    public func status() async throws(JetStreamError) -> KeyValueBucketStatus {
        try await stream.refresh()
        let info = await stream.info
        return KeyValueBucketStatus.from(info)
    }

    // MARK: - Internal Helpers

    /// Get entry including delete/purge markers (for internal use by create)
    private func getEntry(_ key: String) async throws(JetStreamError) -> KeyValueEntry? {
        try validateKey(key)

        let streamName = "KV_\(bucket)"
        let getSubject = "$KV.\(bucket).\(key)"
        let subject = "$JS.API.DIRECT.GET.\(streamName).\(getSubject)"

        do {
            let response = try await context.rawRequest(subject, payload: ByteBuffer())

            if let headers = response.headers, headers.isNoMessages {
                return nil
            }
            if let status = response.headers?.status, status == 404 {
                return nil
            }

            return KeyValueEntry.fromDirectGet(response, bucket: bucket)
        } catch let error as JetStreamError {
            if case .apiError(let code, _, _) = error, code == 404 {
                return nil
            }
            throw error
        }
    }
}

// MARK: - Duration extension

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = self.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
