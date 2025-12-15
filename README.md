# Swift NATS Client

A modern, high-performance NATS client for Swift 6.0 with full JetStream support.

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%20|%20iOS%20|%20Linux-blue.svg)](https://swift.org)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

## Overview

**swift-nats** is a native Swift client library for [NATS](https://nats.io), the cloud-native messaging system. Built from the ground up for Swift 6.0, it leverages modern Swift concurrency features including actors, async/await, and strict sendable checking for thread-safe, high-performance messaging.

### Key Features

- **Swift 6.0 Native** - Built with strict concurrency, actors, and typed throws
- **Full NATS Protocol Support** - Publish, subscribe, request-reply, and queue groups
- **JetStream** - Streams, consumers, and persistent messaging with acknowledgments
- **TLS/mTLS** - Secure connections with full certificate chain support
- **Authentication** - Token, username/password, NKey, and JWT credentials
- **Automatic Reconnection** - Configurable reconnection with exponential backoff
- **AsyncSequence Subscriptions** - Native Swift iteration over messages
- **Cross-Platform** - macOS, iOS, tvOS, watchOS, and Linux

## Requirements

- Swift 6.0+
- macOS 15+ / iOS 18+ / tvOS 18+ / watchOS 11+ / Linux

## Installation

### Swift Package Manager

Add the following to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/swift-nats.git", from: "1.0.0")
]
```

Then add `Nats` to your target dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: ["Nats"]
)
```

## Quick Start

### Basic Connection

```swift
import Nats

// Create client with default settings (localhost:4222)
let client = NatsClient()

// Or configure with custom options
let client = NatsClient {
    $0.servers = [URL(string: "nats://localhost:4222")!]
    $0.name = "my-swift-app"
}

// Connect
try await client.connect()

// Check connection status
if await client.isConnected {
    print("Connected to NATS!")
}

// Close when done
await client.close()
```

### Publish Messages

```swift
// Simple publish
try await client.publish("events.user.created", payload: Data("user123".utf8))

// Publish with headers
var headers = NatsHeaders()
headers["Content-Type"] = "application/json"
try await client.publish("events.order", payload: jsonData, headers: headers)
```

### Subscribe to Messages

```swift
// Subscribe returns an AsyncSequence
let subscription = try await client.subscribe("events.>")

// Iterate over messages
for await message in subscription {
    print("Subject: \(message.subject)")
    print("Payload: \(message.string ?? "")")
}

// Unsubscribe when done
await subscription.unsubscribe()
```

### Request-Reply

```swift
// Send request and wait for response
let response = try await client.request(
    "api.users.get",
    payload: Data("{\"id\": 123}".utf8),
    timeout: .seconds(5)
)

print("Response: \(response.string ?? "")")
```

### Queue Groups

```swift
// Create competing consumers with queue groups
let subscription = try await client.subscribe("tasks.process", queue: "workers")

for await task in subscription {
    // Only one worker in the group receives each message
    processTask(task)
}
```

## JetStream

JetStream provides persistent messaging with streams and consumers.

### Create a Stream

```swift
let js = try await client.jetStream()

// Create a stream
let stream = try await js.createStream(StreamConfig(
    name: "EVENTS",
    subjects: ["events.>"],
    retention: .limits,
    storage: .file,
    maxAge: 86400_000_000_000  // 24 hours in nanoseconds
))

print("Stream created: \(stream.info.config.name)")
```

### Publish with Acknowledgment

```swift
// Publish and get sequence confirmation
let ack = try await js.publish("events.order.created", payload: orderData)
print("Published to stream: \(ack.stream), sequence: \(ack.sequence)")

// Publish with deduplication
let ack = try await js.publish(
    "events.payment",
    payload: paymentData,
    options: PublishOptions(messageID: "payment-123")
)
```

### Create and Use Consumers

```swift
// Create a durable consumer
let consumer = try await js.createConsumer(
    stream: "EVENTS",
    config: ConsumerConfig(
        name: "event-processor",
        deliverPolicy: .all,
        ackPolicy: .explicit,
        ackWait: 30_000_000_000  // 30 seconds
    )
)

// Fetch messages in batches
let messages = try await consumer.fetch(batch: 10, maxWait: .seconds(5))

for message in messages {
    print("Processing: \(message.metadata.streamSequence)")

    // Acknowledge successful processing
    try await message.ack()

    // Or negative acknowledge for redelivery
    // try await message.nak()

    // Or terminate (don't redeliver)
    // try await message.term()
}
```

### Stream as AsyncSequence

```swift
// Consume messages continuously
for await message in try await consumer.messages() {
    do {
        processEvent(message)
        try await message.ack()
    } catch {
        try await message.nak(delay: .seconds(5))
    }
}
```

## TLS Configuration

### Simple TLS

```swift
// Using tls:// scheme
let client = NatsClient {
    $0.servers = [URL(string: "tls://localhost:4222")!]
}

// Or explicit TLS config
let client = NatsClient {
    $0.servers = [URL(string: "nats://localhost:4222")!]
    $0.tls = .enabled
}
```

### TLS with Custom CA

```swift
let client = NatsClient {
    $0.servers = [URL(string: "tls://nats.example.com:4222")!]
    $0.tls = try! TLSConfig.withCustomCA(certificatePath: "/path/to/ca.pem")
}
```

### Mutual TLS (mTLS)

```swift
let client = NatsClient {
    $0.servers = [URL(string: "tls://nats.example.com:4222")!]
    $0.tls = try! TLSConfig.mTLS(
        certificateChainPath: "/path/to/client-cert.pem",
        privateKeyPath: "/path/to/client-key.pem",
        trustRootsPath: "/path/to/ca.pem"
    )
}
```

### Insecure TLS (Testing Only)

```swift
// Skip certificate verification - DO NOT USE IN PRODUCTION
let client = NatsClient {
    $0.servers = [URL(string: "tls://localhost:4222")!]
    $0.tls = .insecure
}
```

## Authentication

### Token Authentication

```swift
let client = NatsClient {
    $0.servers = [URL(string: "nats://localhost:4222")!]
    $0.auth = .token("s3cr3t")
}

// Or via URL
let client = NatsClient {
    try! $0.url("nats://s3cr3t@localhost:4222")
}
```

### Username/Password

```swift
let client = NatsClient {
    $0.servers = [URL(string: "nats://localhost:4222")!]
    $0.auth = .userPass(user: "admin", password: "password123")
}

// Or via URL
let client = NatsClient {
    try! $0.url("nats://admin:password123@localhost:4222")
}
```

### NKey Authentication

```swift
let client = NatsClient {
    $0.servers = [URL(string: "nats://localhost:4222")!]
    $0.auth = .nkey(seed: "SUACSSL3UAHUDXKFSNVUZRF5UHPMWZ6BFDTJ7M6USDXIEDNPPQYYYCU3VY")
}
```

### JWT Credentials

```swift
let client = NatsClient {
    $0.servers = [URL(string: "nats://localhost:4222")!]
    $0.auth = .credentials(URL(fileURLWithPath: "/path/to/user.creds"))
}
```

## Configuration Options

```swift
let client = NatsClient {
    // Server URLs
    $0.servers = [
        URL(string: "nats://server1:4222")!,
        URL(string: "nats://server2:4222")!
    ]

    // Client identification
    $0.name = "my-service"

    // Reconnection settings
    $0.reconnect = ReconnectPolicy(
        enabled: true,
        maxAttempts: 60,
        initialDelay: .milliseconds(100),
        maxDelay: .seconds(5),
        jitter: 0.1
    )

    // TLS configuration
    $0.tls = .enabled

    // Authentication
    $0.auth = .token("secret")

    // Timeouts
    $0.requestTimeout = .seconds(5)
    $0.drainTimeout = .seconds(30)

    // Ping/Pong for connection health
    $0.pingInterval = .seconds(120)
    $0.maxPingsOut = 2

    // Protocol options
    $0.echo = true      // Receive own published messages
    $0.verbose = false  // Disable +OK acknowledgments
    $0.pedantic = false // Disable strict protocol checking

    // Custom inbox prefix
    $0.inboxPrefix = "_INBOX"
}
```

## Error Handling

The library uses typed throws for precise error handling:

```swift
do {
    try await client.connect()
} catch let error as ConnectionError {
    switch error {
    case .connectionRefused(let host, let port):
        print("Cannot connect to \(host):\(port)")
    case .authenticationFailed(let reason):
        print("Auth failed: \(reason)")
    case .tlsHandshakeFailed(let reason):
        print("TLS error: \(reason)")
    case .timeout(let duration):
        print("Connection timeout after \(duration)")
    case .maxReconnectsExceeded(let attempts):
        print("Max reconnection attempts (\(attempts)) exceeded")
    default:
        print("Connection error: \(error)")
    }
}

do {
    try await client.publish("subject", payload: data)
} catch let error as ProtocolError {
    switch error {
    case .invalidSubject(let subject):
        print("Invalid subject: \(subject)")
    case .payloadTooLarge(let size, let max):
        print("Payload \(size) exceeds max \(max)")
    case .noResponders(let subject):
        print("No responders for \(subject)")
    default:
        print("Protocol error: \(error)")
    }
}

do {
    let stream = try await js.createStream(config)
} catch let error as JetStreamError {
    switch error {
    case .notEnabled:
        print("JetStream not enabled on server")
    case .streamNotFound(let name):
        print("Stream not found: \(name)")
    case .apiError(let code, let errCode, let description):
        print("JetStream API error \(code)/\(errCode): \(description)")
    default:
        print("JetStream error: \(error)")
    }
}
```

## Client Statistics

```swift
let stats = client.stats
print("Messages sent: \(stats.messagesSent)")
print("Messages received: \(stats.messagesReceived)")
```

## Graceful Shutdown

```swift
// Drain subscriptions and close
try await client.drain()

// Or immediate close
await client.close()
```

## License

Copyright 2024 Halimjon Juraev, Nexus Technologies, LLC

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## Acknowledgments

- [NATS.io](https://nats.io) - The cloud-native messaging system
- [Swift NIO](https://github.com/apple/swift-nio) - Event-driven network application framework
- [Swift Crypto](https://github.com/apple/swift-crypto) - Cryptographic operations for Swift
