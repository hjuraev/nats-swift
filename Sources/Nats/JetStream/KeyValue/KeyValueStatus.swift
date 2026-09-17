// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Status information for a Key-Value bucket
public struct KeyValueBucketStatus: Sendable {
    /// Bucket name
    public let bucket: String

    /// Number of unique keys (active subjects)
    public let values: Int

    /// Max history entries per key
    public let history: Int

    /// Time-to-live for entries
    public let ttl: Duration?

    /// Maximum value size in bytes
    public let maxValueSize: Int32

    /// Maximum total bytes for the bucket
    public let maxBytes: Int64

    /// Storage backend type
    public let storage: StorageType

    /// Number of replicas
    public let replicas: Int

    /// Total number of entries (including history and delete markers)
    public let totalEntries: UInt64

    /// Total bytes used
    public let totalBytes: UInt64

    /// Compression algorithm
    public let compression: StoreCompression?

    /// User-provided metadata
    public let metadata: [String: String]?

    /// The full underlying stream info
    public let streamInfo: StreamInfo

    /// The oldest revision still stored. A watcher resuming from a revision
    /// below this has lost entries and must replay the bucket.
    public var firstRevision: UInt64 { streamInfo.state.firstSeq }

    /// The newest revision stored.
    public var lastRevision: UInt64 { streamInfo.state.lastSeq }

    /// Construct from StreamInfo
    static func from(_ info: StreamInfo) -> KeyValueBucketStatus {
        let config = info.config
        let bucketName: String
        if config.name.hasPrefix("KV_") {
            bucketName = String(config.name.dropFirst(3))
        } else {
            bucketName = config.name
        }

        // Convert maxAge nanos to Duration
        let ttl: Duration?
        if config.maxAge > 0 {
            let seconds = config.maxAge / 1_000_000_000
            let attoseconds = (config.maxAge % 1_000_000_000) * 1_000_000_000
            ttl = Duration(secondsComponent: Int64(seconds), attosecondsComponent: Int64(attoseconds))
        } else {
            ttl = nil
        }

        return KeyValueBucketStatus(
            bucket: bucketName,
            values: info.state.numSubjects ?? 0,
            history: Int(config.maxMsgsPerSubject),
            ttl: ttl,
            maxValueSize: config.maxMsgSize,
            maxBytes: config.maxBytes,
            storage: config.storage,
            replicas: config.replicas,
            totalEntries: info.state.messages,
            totalBytes: info.state.bytes,
            compression: config.compression,
            metadata: config.metadata,
            streamInfo: info
        )
    }
}
