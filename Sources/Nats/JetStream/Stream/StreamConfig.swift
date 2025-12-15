// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Configuration for creating or updating a JetStream stream
public struct StreamConfig: Codable, Sendable {
    /// A unique name for the stream
    public var name: String

    /// Subjects that this stream will listen on
    public var subjects: [String]

    /// How messages are retained in the stream
    public var retention: RetentionPolicy

    /// Maximum number of consumers allowed
    public var maxConsumers: Int

    /// Maximum number of messages in the stream
    public var maxMsgs: Int64

    /// Maximum bytes in the stream
    public var maxBytes: Int64

    /// Maximum age of messages (in nanoseconds)
    public var maxAge: Int64

    /// Maximum message size
    public var maxMsgSize: Int32

    /// Storage backend type
    public var storage: StorageType

    /// Number of replicas for the stream
    public var replicas: Int

    /// Discard policy when limits are reached
    public var discard: DiscardPolicy

    /// Window for duplicate message detection (in nanoseconds)
    public var duplicateWindow: Int64

    /// Maximum messages per subject
    public var maxMsgsPerSubject: Int64

    /// Whether to allow rollup headers
    public var allowRollupHdrs: Bool

    /// Whether to deny delete
    public var denyDelete: Bool

    /// Whether to deny purge
    public var denyPurge: Bool

    /// Whether to allow direct gets
    public var allowDirect: Bool

    /// Mirror configuration
    public var mirror: StreamSource?

    /// Source streams
    public var sources: [StreamSource]?

    /// Description of the stream
    public var description: String?

    /// Placement preferences
    public var placement: Placement?

    /// Re-publish configuration
    public var republish: Republish?

    public init(
        name: String,
        subjects: [String] = [],
        retention: RetentionPolicy = .limits,
        maxConsumers: Int = -1,
        maxMsgs: Int64 = -1,
        maxBytes: Int64 = -1,
        maxAge: Duration = .zero,
        maxMsgSize: Int32 = -1,
        storage: StorageType = .file,
        replicas: Int = 1,
        discard: DiscardPolicy = .old,
        duplicateWindow: Duration = .seconds(120),
        maxMsgsPerSubject: Int64 = -1,
        allowRollupHdrs: Bool = false,
        denyDelete: Bool = false,
        denyPurge: Bool = false,
        allowDirect: Bool = true,
        mirror: StreamSource? = nil,
        sources: [StreamSource]? = nil,
        description: String? = nil,
        placement: Placement? = nil,
        republish: Republish? = nil
    ) {
        self.name = name
        self.subjects = subjects
        self.retention = retention
        self.maxConsumers = maxConsumers
        self.maxMsgs = maxMsgs
        self.maxBytes = maxBytes
        self.maxAge = Int64(maxAge.components.seconds * 1_000_000_000)
        self.maxMsgSize = maxMsgSize
        self.storage = storage
        self.replicas = replicas
        self.discard = discard
        self.duplicateWindow = Int64(duplicateWindow.components.seconds * 1_000_000_000)
        self.maxMsgsPerSubject = maxMsgsPerSubject
        self.allowRollupHdrs = allowRollupHdrs
        self.denyDelete = denyDelete
        self.denyPurge = denyPurge
        self.allowDirect = allowDirect
        self.mirror = mirror
        self.sources = sources
        self.description = description
        self.placement = placement
        self.republish = republish
    }

    enum CodingKeys: String, CodingKey {
        case name
        case subjects
        case retention
        case maxConsumers = "max_consumers"
        case maxMsgs = "max_msgs"
        case maxBytes = "max_bytes"
        case maxAge = "max_age"
        case maxMsgSize = "max_msg_size"
        case storage
        case replicas = "num_replicas"
        case discard
        case duplicateWindow = "duplicate_window"
        case maxMsgsPerSubject = "max_msgs_per_subject"
        case allowRollupHdrs = "allow_rollup_hdrs"
        case denyDelete = "deny_delete"
        case denyPurge = "deny_purge"
        case allowDirect = "allow_direct"
        case mirror
        case sources
        case description
        case placement
        case republish
    }
}

// MARK: - Supporting Types

/// Message retention policy
public enum RetentionPolicy: String, Codable, Sendable {
    /// Keep messages until explicitly deleted or limits exceeded
    case limits

    /// Keep messages only while there are interested consumers
    case interest

    /// Each message is consumed exactly once (work queue pattern)
    case workqueue
}

/// Storage backend type
public enum StorageType: String, Codable, Sendable {
    /// Store on disk
    case file

    /// Store in memory
    case memory
}

/// Policy for discarding messages when limits are reached
public enum DiscardPolicy: String, Codable, Sendable {
    /// Discard old messages first
    case old

    /// Discard new messages
    case new
}

/// Stream source for mirroring or sourcing
public struct StreamSource: Codable, Sendable {
    /// Name of the source stream
    public var name: String

    /// Starting sequence number
    public var optStartSeq: UInt64?

    /// Starting time
    public var optStartTime: Date?

    /// Filter subject
    public var filterSubject: String?

    /// External stream reference
    public var external: ExternalStream?

    public init(
        name: String,
        optStartSeq: UInt64? = nil,
        optStartTime: Date? = nil,
        filterSubject: String? = nil,
        external: ExternalStream? = nil
    ) {
        self.name = name
        self.optStartSeq = optStartSeq
        self.optStartTime = optStartTime
        self.filterSubject = filterSubject
        self.external = external
    }

    enum CodingKeys: String, CodingKey {
        case name
        case optStartSeq = "opt_start_seq"
        case optStartTime = "opt_start_time"
        case filterSubject = "filter_subject"
        case external
    }
}

/// External stream reference for cross-domain access
public struct ExternalStream: Codable, Sendable {
    /// API prefix for the external domain
    public var api: String

    /// Delivery prefix
    public var deliver: String?

    public init(api: String, deliver: String? = nil) {
        self.api = api
        self.deliver = deliver
    }
}

/// Placement preferences for stream
public struct Placement: Codable, Sendable {
    /// Cluster name
    public var cluster: String?

    /// Tags for server selection
    public var tags: [String]?

    public init(cluster: String? = nil, tags: [String]? = nil) {
        self.cluster = cluster
        self.tags = tags
    }
}

/// Republish configuration
public struct Republish: Codable, Sendable {
    /// Source subject pattern
    public var src: String

    /// Destination subject pattern
    public var dest: String

    /// Whether to include headers only
    public var headersOnly: Bool?

    public init(src: String, dest: String, headersOnly: Bool? = nil) {
        self.src = src
        self.dest = dest
        self.headersOnly = headersOnly
    }

    enum CodingKeys: String, CodingKey {
        case src
        case dest
        case headersOnly = "headers_only"
    }
}
