import Foundation
import NIOCore
import NIOHTTP1
import NIOWebSocket

let inboundMessageLimit = 2 * 1024 * 1024
let outboundMessageLimit = 1024 * 1024

func maskedFrame(opcode: WebSocketOpcode, data: ByteBuffer) -> WebSocketFrame {
    var random = SystemRandomNumberGenerator()
    let key = WebSocketMaskingKey((0..<4).map { _ in UInt8.random(in: .min ... .max, using: &random) })
    return WebSocketFrame(fin: true, opcode: opcode, maskKey: key, data: data)
}

final class MessageHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    let resources: SessionResources
    private var fragments: ByteBuffer?
    init(resources: SessionResources) { self.resources = resources }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        // The server must not mask frames, and extensions have not been negotiated.
        guard frame.maskKey == nil, !frame.rsv1, !frame.rsv2, !frame.rsv3 else { fail(.protocolViolation, context); return }
        var payload = frame.unmaskedData
        if frame.opcode == .ping || frame.opcode == .pong || frame.opcode == .connectionClose {
            guard frame.fin, payload.readableBytes <= 125 else { fail(.protocolViolation, context); return }
            if frame.opcode == .ping {
                context.writeAndFlush(wrapOutboundOut(maskedFrame(opcode: .pong, data: payload)), promise: nil)
            } else if frame.opcode == .connectionClose {
                guard payload.readableBytes != 1 else { fail(.protocolViolation, context); return }
                if payload.readableBytes >= 2 {
                    let code = payload.getInteger(at: payload.readerIndex, as: UInt16.self)!
                    let permitted = (1000...1014).contains(code) && ![1004,1005,1006].contains(code) || (3000...4999).contains(code)
                    let reason = payload.getSlice(at: payload.readerIndex + 2, length: payload.readableBytes - 2)!
                    guard permitted, String(bytes: reason.readableBytesView, encoding: .utf8) != nil else { fail(.protocolViolation, context); return }
                }
                context.writeAndFlush(wrapOutboundOut(maskedFrame(opcode: .connectionClose, data: payload))).whenComplete { [resources] _ in resources.close() }
            }
            return
        }
        guard frame.opcode == .text || frame.opcode == .continuation else { fail(.protocolViolation, context); return }
        if frame.opcode == .text {
            guard fragments == nil else { fail(.protocolViolation, context); return }
            guard payload.readableBytes <= inboundMessageLimit else { fail(.messageTooLarge, context); return }
            if frame.fin { deliver(payload, context) } else { fragments = payload }
        } else {
            guard var accumulated = fragments else { fail(.protocolViolation, context); return }
            guard payload.readableBytes <= inboundMessageLimit - accumulated.readableBytes else { fail(.messageTooLarge, context); return }
            accumulated.writeBuffer(&payload)
            if frame.fin { fragments = nil; deliver(accumulated, context) } else { fragments = accumulated }
        }
    }
    private func deliver(_ data: ByteBuffer, _ context: ChannelHandlerContext) {
        guard let text = String(bytes: data.readableBytesView, encoding: .utf8) else { fail(.protocolViolation, context); return }
        switch resources.continuation.yield(text) {
        case .dropped: fail(.receiveBufferFull, context)
        case .terminated: resources.close()
        case .enqueued: break
        @unknown default: fail(.protocolViolation, context)
        }
    }
    private func fail(_ error: SSHTransportError, _ context: ChannelHandlerContext) {
        resources.record(error)
        resources.close(error: error)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Decoder errors can contain peer-controlled data. Return only a typed safe error.
        resources.close(error: (error as? NIOWebSocketError) == .invalidFrameLength ? SSHTransportError.messageTooLarge : SSHTransportError.protocolViolation)
    }
    func channelInactive(context: ChannelHandlerContext) {
        resources.close(error: resources.error(or: .disconnected))
        context.fireChannelInactive()
    }
}

final class UpgradeRequestHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    private let token: String
    private let port: Int
    private let upgraded: PhaseCompletion
    private let resources: SessionResources
    private var finished = false
    init(token: String, port: Int, upgraded: PhaseCompletion, resources: SessionResources) {
        self.token = token; self.port = port; self.upgraded = upgraded; self.resources = resources
    }
    func handlerAdded(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "127.0.0.1:\(port)")
        headers.add(name: "Authorization", value: "Bearer \(token)")
        headers.add(name: "Content-Length", value: "0")
        context.write(wrapOutboundOut(.head(.init(version: .http1_1, method: .GET, uri: "/", headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let head) = unwrapInboundIn(data), !finished {
            finished = true
            let error = SSHTransportError.webSocketRejected(status: Int(head.status.code))
            resources.record(error); upgraded.fail(error); resources.close(error: error)
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !finished { finished = true; upgraded.fail(resources.error(or: .protocolViolation)) }
        resources.close(error: resources.error(or: .protocolViolation))
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !finished { finished = true; upgraded.fail(resources.error(or: .disconnected)) }
        context.fireChannelInactive()
    }
    /// Called immediately before removing this HTTP-only handler after the valid 101 response.
    func willUpgrade() { finished = true }
}
