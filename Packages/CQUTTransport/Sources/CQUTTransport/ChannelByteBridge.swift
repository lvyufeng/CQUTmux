import NIOCore
import NIOSSH

/// Adapts a channel that speaks `SSHChannelData` (a `direct-tcpip` channel) so
/// a plain `ByteBuffer` protocol — `NIOSSHHandler` — can sit on top of it.
///
/// `NIOSSHHandler` reads and writes `ByteBuffer`; an SSH child channel reads
/// and writes `SSHChannelData`. Wrapping the payload in both directions is all
/// it takes to run a whole second SSH connection over one forwarded channel,
/// which is what a jump host is.
///
/// Install it *before* `NIOSSHHandler`: the outbound-unwrap handler must be
/// innermost so it sees the buffer on its way to the wire.
final class ByteBufferToSSHDataHandler: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }

    /// Channel close and flush have no byte-level equivalent; pass them along.
    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        context.close(mode: mode, promise: promise)
    }
}

/// The inbound half: unwraps `SSHChannelData` back into `ByteBuffer` for the
/// handlers above. EOF and channel close are left alone — `NIOSSHHandler`
/// reads them as its transport dying, which is exactly what happened.
final class SSHDataToByteBufferHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = payload.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }
}