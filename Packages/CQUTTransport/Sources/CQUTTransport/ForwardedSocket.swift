import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// A byte pipe over an SSH channel opened with `forward`. Used for the host's
/// loopback gateway; not a general-purpose socket abstraction.
public final class ForwardedSocket: @unchecked Sendable {
    private let onData: @Sendable (Data) -> Void
    private let onClose: @Sendable () -> Void
    private var channel: Channel?
    private let lock = NSLock()
    private var closed = false

    init(channel: Channel, onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        self.channel = channel
        self.onData = onData
        self.onClose = onClose
    }

    func attach(_ channel: Channel) {
        lock.lock()
        self.channel = channel
        lock.unlock()
    }

    func fail() {
        onClose()
    }

    public func send(_ data: Data) {
        lock.lock()
        let channel = self.channel
        lock.unlock()
        guard let channel else { return }
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
        }
    }

    public func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let channel = self.channel
        lock.unlock()
        channel?.close(promise: nil)
    }

    /// Shared inbound handler for a forwarded channel.
    final class Handler: ChannelInboundHandler {
        typealias InboundIn = SSHChannelData

        private let onData: @Sendable (Data) -> Void
        private let onClose: @Sendable () -> Void

        init(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
            self.onData = onData
            self.onClose = onClose
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let payload = unwrapInboundIn(data)
            guard case .byteBuffer(var buffer) = payload.data,
                  let bytes = buffer.readBytes(length: buffer.readableBytes),
                  !bytes.isEmpty
            else { return }
            onData(Data(bytes))
        }

        func channelInactive(context: ChannelHandlerContext) {
            onClose()
        }
    }
}

typealias ForwardedChannelHandler = ForwardedSocket.Handler