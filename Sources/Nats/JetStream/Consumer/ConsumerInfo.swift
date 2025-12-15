// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Information about a JetStream consumer
public struct ConsumerInfo: Codable, Sendable {
    /// Stream the consumer is attached to
    public let streamName: String

    /// Consumer name
    public let name: String

    /// When the consumer was created
    public let created: Date

    /// Consumer configuration
    public let config: ConsumerConfig

    /// Delivery state
    public let delivered: SequenceInfo

    /// Acknowledgement floor
    public let ackFloor: SequenceInfo

    /// Number of pending acknowledgements
    public let numAckPending: Int

    /// Number of redelivered messages
    public let numRedelivered: Int

    /// Number of waiting pull requests
    public let numWaiting: Int

    /// Number of pending messages
    public let numPending: UInt64

    /// Cluster information
    public let cluster: ClusterInfo?

    /// Whether bound to a push subscription
    public let pushBound: Bool?

    enum CodingKeys: String, CodingKey {
        case streamName = "stream_name"
        case name
        case created
        case config
        case delivered
        case ackFloor = "ack_floor"
        case numAckPending = "num_ack_pending"
        case numRedelivered = "num_redelivered"
        case numWaiting = "num_waiting"
        case numPending = "num_pending"
        case cluster
        case pushBound = "push_bound"
    }
}

/// Sequence tracking information
public struct SequenceInfo: Codable, Sendable {
    /// Consumer sequence number
    public let consumerSeq: UInt64

    /// Stream sequence number
    public let streamSeq: UInt64

    /// Last activity time (nanoseconds since epoch, optional)
    public let lastActive: Date?

    enum CodingKeys: String, CodingKey {
        case consumerSeq = "consumer_seq"
        case streamSeq = "stream_seq"
        case lastActive = "last_active"
    }
}

/// Account information for JetStream
public struct AccountInfo: Codable, Sendable {
    /// Memory used
    public let memory: Int64

    /// Storage used
    public let storage: Int64

    /// Number of streams
    public let streams: Int

    /// Number of consumers
    public let consumers: Int

    /// Domain (optional)
    public let domain: String?

    /// API usage statistics
    public let api: APIStats

    /// Account limits
    public let limits: AccountLimits

    enum CodingKeys: String, CodingKey {
        case memory
        case storage
        case streams
        case consumers
        case domain
        case api
        case limits
    }
}

/// API usage statistics
public struct APIStats: Codable, Sendable {
    /// Total number of API calls
    public let total: Int64

    /// Number of errors
    public let errors: Int64
}

/// Account limits
public struct AccountLimits: Codable, Sendable {
    /// Maximum memory
    public let maxMemory: Int64

    /// Maximum storage
    public let maxStorage: Int64

    /// Maximum streams
    public let maxStreams: Int

    /// Maximum consumers
    public let maxConsumers: Int

    /// Maximum ack pending
    public let maxAckPending: Int

    /// Maximum bytes per stream
    public let memoryMaxStreamBytes: Int64

    /// Maximum bytes per storage stream
    public let storageMaxStreamBytes: Int64

    /// Maximum request batch
    public let maxBytesRequired: Bool

    enum CodingKeys: String, CodingKey {
        case maxMemory = "max_memory"
        case maxStorage = "max_storage"
        case maxStreams = "max_streams"
        case maxConsumers = "max_consumers"
        case maxAckPending = "max_ack_pending"
        case memoryMaxStreamBytes = "memory_max_stream_bytes"
        case storageMaxStreamBytes = "storage_max_stream_bytes"
        case maxBytesRequired = "max_bytes_required"
    }
}
