// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Information about a JetStream stream
public struct StreamInfo: Codable, Sendable {
    /// Stream configuration
    public let config: StreamConfig

    /// When the stream was created
    public let created: Date

    /// Current stream state
    public let state: StreamState

    /// Cluster information (if clustered)
    public let cluster: ClusterInfo?

    /// Mirror information (if mirroring)
    public let mirror: StreamSourceInfo?

    /// Sources information (if sourcing)
    public let sources: [StreamSourceInfo]?

    enum CodingKeys: String, CodingKey {
        case config
        case created
        case state
        case cluster
        case mirror
        case sources
    }
}

/// Current state of a stream
public struct StreamState: Codable, Sendable {
    /// Number of messages in the stream
    public let messages: UInt64

    /// Total bytes in the stream
    public let bytes: UInt64

    /// First sequence number
    public let firstSeq: UInt64

    /// Timestamp of first message
    public let firstTs: Date

    /// Last sequence number
    public let lastSeq: UInt64

    /// Timestamp of last message
    public let lastTs: Date

    /// Number of deleted messages
    public let numDeleted: Int?

    /// Deleted message sequence numbers (if available)
    public let deleted: [UInt64]?

    /// Lost message information
    public let lost: LostStreamData?

    /// Number of consumers
    public let consumerCount: Int

    /// Number of unique subjects
    public let numSubjects: Int?

    enum CodingKeys: String, CodingKey {
        case messages
        case bytes
        case firstSeq = "first_seq"
        case firstTs = "first_ts"
        case lastSeq = "last_seq"
        case lastTs = "last_ts"
        case numDeleted = "num_deleted"
        case deleted
        case lost
        case consumerCount = "consumer_count"
        case numSubjects = "num_subjects"
    }
}

/// Information about lost/damaged messages
public struct LostStreamData: Codable, Sendable {
    /// Sequence numbers of lost messages
    public let msgs: [UInt64]?

    /// Total bytes lost
    public let bytes: UInt64?
}

/// Cluster information for a stream
public struct ClusterInfo: Codable, Sendable {
    /// Cluster name
    public let name: String?

    /// Current leader
    public let leader: String?

    /// Replicas
    public let replicas: [PeerInfo]?
}

/// Peer/replica information
public struct PeerInfo: Codable, Sendable {
    /// Peer name
    public let name: String

    /// Whether peer is current
    public let current: Bool

    /// Whether peer is offline
    public let offline: Bool?

    /// How far behind the peer is
    public let lag: UInt64?

    /// Active time
    public let active: Int64?
}

/// Information about a stream source
public struct StreamSourceInfo: Codable, Sendable {
    /// Source name
    public let name: String

    /// Current lag
    public let lag: UInt64

    /// Active time (nanoseconds)
    public let active: Int64

    /// Filter subject
    public let filterSubject: String?

    /// External reference
    public let external: ExternalStream?

    enum CodingKeys: String, CodingKey {
        case name
        case lag
        case active
        case filterSubject = "filter_subject"
        case external
    }
}
