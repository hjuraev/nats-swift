// Copyright 2024 Halimjon Juraev
// Nexus Technologies, LLC
// Licensed under the Apache License, Version 2.0

import NIOCore
import NIOTLS

/// Reports when the TLS handshake on this channel has completed.
///
/// Adding `NIOSSLClientHandler` to the pipeline *starts* the handshake; it does
/// not wait for it, and NIOSSL buffers every outbound write until it finishes.
/// Without this the client cannot tell a peer that never answered the
/// ClientHello from a peer that never sent INFO — both simply run out the
/// connect deadline and report a bare timeout.
final class TLSHandshakeObserver: ChannelInboundHandler {
    typealias InboundIn = Any
    typealias InboundOut = Any

    private let onHandshakeCompleted: @Sendable () -> Void

    init(onHandshakeCompleted: @escaping @Sendable () -> Void) {
        self.onHandshakeCompleted = onHandshakeCompleted
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            onHandshakeCompleted()
        }
        context.fireUserInboundEventTriggered(event)
    }
}
