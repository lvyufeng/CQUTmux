import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// A byte pipe over an SSH channel opened with `forward`. Used for the host's
/// loopback gateway; not a general-purpose socket abstraction.
///
/// The child channel arrives asynchronously, so writes issued before it is
/// attached are buffered here. Writing `SSHChannelData` to the parent
/// connection channel instead would trap inside NIO (`forceAsIOData`).
public final class ForwardedSocket: @unchecked Sendable {
    private let onData: @Sendable (Data) -> Void
    private let onClose: @Sendable () -> Void
    private let lock = NSLock()
    private var channel: Channel?
    private var pending: [Data] = []
    private var closed = false
    private var didFail = false

    init(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        self.onData = onData
        self.onClose = onClose
    }

    func attach(_ channel: Channel) {
        lock.lock()
        self.channel = channel
        let queued = pending
        pending = []
        let isClosed = closed
        lock.unlock()

        guard !isClosed else {
            channel.close(promise: nil)
            return
        }
        for data in queued { write(data, to: channel) }
    }

    func fail() {
        lock.lock()
        if didFail { lock.unlock(); return }
        didFail = true
        lock.unlock()
        onClose()
    }

    public func send(_ data: Data) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        guard let channel else {
            pending.append(data)
            lock.unlock()
            return
        }
        lock.unlock()
        write(data, to: channel)
    }

    private func write(_ data: Data, to channel: Channel) {
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
        pending = []
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