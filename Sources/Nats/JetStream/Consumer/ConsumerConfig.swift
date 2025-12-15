// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation

/// Configuration for creating a JetStream consumer
public struct ConsumerConfig: Codable, Sendable {
    /// Consumer name (for durable consumers)
    public var name: String?

    /// Durable name (legacy, use name instead)
    public var durable: String?

    /// Description of the consumer
    public var description: String?

    /// Subject for push delivery
    public var deliverSubject: String?

    /// Deliver group for queue subscriptions
    public var deliverGroup: String?

    /// Policy for message delivery starting point
    public var deliverPolicy: DeliverPolicy

    /// Starting sequence number (for byStartSequence policy)
    public var optStartSeq: UInt64?

    /// Starting time (for byStartTime policy)
    public var optStartTime: Date?

    /// Acknowledgement policy
    public var ackPolicy: AckPolicy

    /// Time to wait for acknowledgement (nanoseconds)
    public var ackWait: Int64

    /// Maximum delivery attempts
    public var maxDeliver: Int

    /// Backoff durations for redelivery (nanoseconds)
    public var backoff: [Int64]?

    /// Filter subject
    public var filterSubject: String?

    /// Multiple filter subjects
    public var filterSubjects: [String]?

    /// Replay policy
    public var replayPolicy: ReplayPolicy

    /// Rate limit in bits per second
    public var rateLimitBps: UInt64?

    /// Sample frequency for acknowledgements (percentage as string "100%")
    public var sampleFreq: String?

    /// Maximum outstanding acknowledgements
    public var maxAckPending: Int

    /// Maximum waiting pull requests
    public var maxWaiting: Int?

    /// Maximum batch size for pull
    public var maxBatch: Int?

    /// Maximum bytes for pull
    public var maxBytes: Int?

    /// Maximum expiry for pull requests (nanoseconds)
    public var maxExpires: Int64?

    /// Inactivity threshold for ephemeral consumers (nanoseconds)
    public var inactiveThreshold: Int64?

    /// Number of replicas
    public var numReplicas: Int

    /// Use memory storage
    public var memStorage: Bool?

    /// Whether to deliver headers only
    public var headersOnly: Bool?

    /// Enable flow control
    public var flowControl: Bool?

    /// Idle heartbeat interval (nanoseconds)
    public var idleHeartbeat: Int64?

    /// Metadata
    public var metadata: [String: String]?

    public init(
        name: String? = nil,
        durable: String? = nil,
        description: String? = nil,
        deliverSubject: String? = nil,
        deliverGroup: String? = nil,
        deliverPolicy: DeliverPolicy = .all,
        optStartSeq: UInt64? = nil,
        optStartTime: Date? = nil,
        ackPolicy: AckPolicy = .explicit,
        ackWait: Duration = .seconds(30),
        maxDeliver: Int = -1,
        backoff: [Duration]? = nil,
        filterSubject: String? = nil,
        filterSubjects: [String]? = nil,
        replayPolicy: ReplayPolicy = .instant,
        rateLimitBps: UInt64? = nil,
        sampleFreq: String? = nil,
        maxAckPending: Int = 1000,
        maxWaiting: Int? = nil,
        maxBatch: Int? = nil,
        maxBytes: Int? = nil,
        maxExpires: Duration? = nil,
        inactiveThreshold: Duration? = nil,
        numReplicas: Int = 0,
        memStorage: Bool? = nil,
        headersOnly: Bool? = nil,
        flowControl: Bool? = nil,
        idleHeartbeat: Duration? = nil,
        metadata: [String: String]? = nil
    ) {
        self.name = name
        self.durable = durable
        self.description = description
        self.deliverSubject = deliverSubject
        self.deliverGroup = deliverGroup
        self.deliverPolicy = deliverPolicy
        self.optStartSeq = optStartSeq
        self.optStartTime = optStartTime
        self.ackPolicy = ackPolicy
        self.ackWait = Int64(ackWait.components.seconds * 1_000_000_000)
        self.maxDeliver = maxDeliver
        self.backoff = backoff?.map { Int64($0.components.seconds * 1_000_000_000) }
        self.filterSubject = filterSubject
        self.filterSubjects = filterSubjects
        self.replayPolicy = replayPolicy
        self.rateLimitBps = rateLimitBps
        self.sampleFreq = sampleFreq
        self.maxAckPending = maxAckPending
        self.maxWaiting = maxWaiting
        self.maxBatch = maxBatch
        self.maxBytes = maxBytes
        self.maxExpires = maxExpires.map { Int64($0.components.seconds * 1_000_000_000) }
        self.inactiveThreshold = inactiveThreshold.map { Int64($0.components.seconds * 1_000_000_000) }
        self.numReplicas = numReplicas
        self.memStorage = memStorage
        self.headersOnly = headersOnly
        self.flowControl = flowControl
        self.idleHeartbeat = idleHeartbeat.map { Int64($0.components.seconds * 1_000_000_000) }
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case name
        case durable = "durable_name"
        case description
        case deliverSubject = "deliver_subject"
        case deliverGroup = "deliver_group"
        case deliverPolicy = "deliver_policy"
        case optStartSeq = "opt_start_seq"
        case optStartTime = "opt_start_time"
        case ackPolicy = "ack_policy"
        case ackWait = "ack_wait"
        case maxDeliver = "max_deliver"
        case backoff
        case filterSubject = "filter_subject"
        case filterSubjects = "filter_subjects"
        case replayPolicy = "replay_policy"
        case rateLimitBps = "rate_limit_bps"
        case sampleFreq = "sample_freq"
        case maxAckPending = "max_ack_pending"
        case maxWaiting = "max_waiting"
        case maxBatch = "max_batch"
        case maxBytes = "max_bytes"
        case maxExpires = "max_expires"
        case inactiveThreshold = "inactive_threshold"
        case numReplicas = "num_replicas"
        case memStorage = "mem_storage"
        case headersOnly = "headers_only"
        case flowControl = "flow_control"
        case idleHeartbeat = "idle_heartbeat"
        case metadata
    }
}

// MARK: - Policies

/// Policy for selecting the starting point for message delivery
public enum DeliverPolicy: String, Codable, Sendable {
    /// Deliver all available messages
    case all

    /// Deliver only the last message
    case last

    /// Deliver only new messages (created after consumer creation)
    case new

    /// Deliver starting from a specific sequence number
    case byStartSequence = "by_start_sequence"

    /// Deliver starting from a specific time
    case byStartTime = "by_start_time"

    /// Deliver the last message for each subject
    case lastPerSubject = "last_per_subject"
}

/// Acknowledgement policy for messages
public enum AckPolicy: String, Codable, Sendable {
    /// No acknowledgement required
    case none

    /// All messages must be explicitly acknowledged
    case explicit

    /// Acknowledging a message acknowledges all previous messages
    case all
}

/// Policy for replaying messages
public enum ReplayPolicy: String, Codable, Sendable {
    /// Replay messages as fast as possible
    case instant

    /// Replay messages at the original rate
    case original
}
