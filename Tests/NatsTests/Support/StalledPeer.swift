// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import Foundation
import NIOCore
import NIOPosix

/// A TCP peer that completes the connection and then misbehaves in one specific,
/// controllable way.
///
/// Every unbounded-wait defect in this client needs a peer that is *reachable but
/// unhelpful* — a refused connection fails early and never exercises the code
/// under test. A real `nats-server` cannot be made to stall on demand, so these
/// stand in for it.
///
/// The suite historically had no fixture like this, which is the direct reason a
/// series of hangs and races reached production: every test asserted that
/// operations *succeed*, none that they are *bounded*.
final class StalledPeer: Sendable {

    /// How the peer misbehaves once the TCP connection is up.
    enum Behaviour: Sendable {
        /// Accept and send nothing, ever. The client reaches its handshake wait
        /// and stays there.
        case silent

        /// Accept, send a valid INFO, then never drain the receive window, so
        /// the client's CONNECT write has nowhere to go once buffers fill.
        case sendInfoThenStopReading

        /// Accept and never read at all — a TCP zero-window peer. Saturates the
        /// client's send buffer.
        case stopReading

        /// Accept and send an INFO advertising `tls_required`, then ignore the
        /// TLS ClientHello entirely. NIOSSL buffers outbound writes until the
        /// handshake completes, so anything written after this stalls.
        case sendTLSInfoThenStall

        /// Whether this behaviour writes an INFO frame on connect.
        var sendsInfo: Bool {
            switch self {
            case .silent, .stopReading: return false
            case .sendInfoThenStopReading, .sendTLSInfoThenStall: return true
            }
        }

        /// Whether the peer should keep draining its receive window.
        var reads: Bool {
            switch self {
            case .silent: return true
            case .sendInfoThenStopReading, .stopReading, .sendTLSInfoThenStall: return false
            }
        }

        var advertisesTLS: Bool {
            if case .sendTLSInfoThenStall = self { return true }
            return false
        }
    }

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    let port: Int

    private init(group: MultiThreadedEventLoopGroup, channel: Channel, port: Int) {
        self.group = group
        self.channel = channel
        self.port = port
    }

    var url: URL {
        URL(string: "nats://127.0.0.1:\(port)")!
    }

    static func start(_ behaviour: Behaviour) async throws -> StalledPeer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Not reading is what creates back-pressure on the client. With
            // autoRead off and no explicit read(), the receive window closes.
            .childChannelOption(ChannelOptions.autoRead, value: behaviour.reads)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(StalledPeerHandler(behaviour: behaviour))
            }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()

        guard let port = channel.localAddress?.port else {
            try? await channel.close()
            try? await group.shutdownGracefully()
            throw StalledPeerError.noPort
        }
        return StalledPeer(group: group, channel: channel, port: port)
    }

    func stop() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }

    enum StalledPeerError: Error {
        case noPort
    }
}

/// Writes the configured greeting on connect and then does nothing else.
private final class StalledPeerHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let behaviour: StalledPeer.Behaviour

    init(behaviour: StalledPeer.Behaviour) {
        self.behaviour = behaviour
    }

    func channelActive(context: ChannelHandlerContext) {
        guard behaviour.sendsInfo else { return }

        var buffer = context.channel.allocator.buffer(capacity: 256)
        buffer.writeString(Self.infoFrame(tlsRequired: behaviour.advertisesTLS))
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Deliberately ignored. These peers never answer.
    }

    /// A minimal INFO the client's decoder accepts. Keys must match
    /// `ServerInfo.CodingKeys`.
    private static func infoFrame(tlsRequired: Bool) -> String {
        let fields: [String] = [
            "\"server_id\":\"STALLEDPEER\"",
            "\"server_name\":\"stalled-peer\"",
            "\"version\":\"2.12.4\"",
            "\"proto\":1",
            "\"host\":\"127.0.0.1\"",
            "\"port\":0",
            "\"headers\":true",
            "\"max_payload\":1048576",
            tlsRequired ? "\"tls_required\":true" : "\"tls_required\":false",
        ]
        return "INFO {\(fields.joined(separator: ","))}\r\n"
    }
}
