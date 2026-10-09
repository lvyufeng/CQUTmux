import Foundation
import NIOCore
import NIOSSH

/// Serves the forwarded identity on one `auth-agent@openssh.com` channel.
///
/// The framing is a 4-byte big-endian length followed by that many bytes of
/// message, and a channel may carry several — nothing in the protocol says a
/// request arrives alone, and a server doing two `git` operations at once will
/// interleave them. So bytes accumulate until a whole message is present and
/// are consumed one at a time; treating each read as one message is the bug
/// that only shows up under concurrency.
final class SSHAgentChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let agent: SSHAgent
    private var buffer = Data()

    init(agent: SSHAgent) {
        self.agent = agent
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = payload.data,
              let read = bytes.readBytes(length: bytes.readableBytes),
              !read.isEmpty
        else { return }

        buffer.append(contentsOf: read)

        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            // A request longer than this is not a request we implement, and
            // waiting for it to arrive would wedge the channel.
            guard length <= 1 << 20 else {
                buffer.removeAll()
                return
            }
            guard buffer.count >= 4 + length else { return }

            let payload = buffer.dropFirst(4).prefix(length)
            buffer.removeFirst(4 + length)

            // `reply(for:)` never throws: a request we cannot serve becomes
            // SSH_AGENT_FAILURE, so the server tries its next key instead of
            // tearing the channel down.
            write(agent.reply(for: Data(payload)), context: context)
        }
    }

    private func write(_ payload: Data, context: ChannelHandlerContext) {
        var framed = context.channel.allocator.buffer(capacity: payload.count + 4)
        framed.writeInteger(UInt32(payload.count))
        framed.writeBytes(payload)
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(framed))), promise: nil)
    }
}