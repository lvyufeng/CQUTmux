import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto

private enum SSHTransportError: Error, CustomStringConvertible {
    case unexpectedChannelType
    case missingHandler
    case authenticationFailed
    case unsupportedAuthMethod

    var description: String {
        switch self {
        case .unexpectedChannelType: "unexpected SSH channel type"
        case .missingHandler: "SSH handler unavailable"
        case .authenticationFailed: "authentication failed — check the username and password or key"
        case .unsupportedAuthMethod: "the server does not accept the configured authentication method"
        }
    }
}

/// A client-side user-auth delegate. Offers the configured credential and,
/// when the server only accepts public keys, signs with the derived key.
private final class CredentialAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let credential: SSHCredential
    /// The server calls back after a rejected attempt. Offer the credential
    /// exactly once — re-offering it loops forever against a server that is
    /// simply refusing us, and the connection would hang with no error.
    private var didOffer = false

    init(username: String, credential: SSHCredential) {
        self.username = username
        self.credential = credential
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // The server rejected the credential and is asking again. Failing the
// promise surfaces the failure as a pipeline error; succeeding with `nil`
// would leave the connection hanging with no callback at all.
        guard !didOffer else {
            return nextChallengePromise.fail(SSHTransportError.authenticationFailed)
        }

        switch credential {
        case .password(let password):
            guard availableMethods.contains(.password) else {
                return nextChallengePromise.fail(SSHTransportError.unsupportedAuthMethod)
            }
            didOffer = true
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "",
                    offer: .password(.init(password: password))
                )
            )

        case .ed25519Seed(let seed):
            guard availableMethods.contains(.publicKey) else {
                return nextChallengePromise.fail(SSHTransportError.unsupportedAuthMethod)
            }
            do {
                let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                didOffer = true
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(
                        username: username,
                        serviceName: "",
                        offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: privateKey)))
                    )
                )
            } catch {
                nextChallengePromise.fail(error)
            }
        }
    }
}

/// Accepts every host key on first connect. Host-key pinning (TOFU) is a
/// follow-up; see PLAN.md Phase 1 notes.
private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

/// Forward any pipeline error to the transport owner and tear the channel down.
private final class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let onError: @Sendable (Error) -> Void

    init(onError: @escaping @Sendable (Error) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

/// Owns one SSH shell child channel: requests the PTY, runs the shell and
/// pipes bytes in both directions.
private final class ShellChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let configuration: TransportConfiguration
    private let initialSize: (cols: Int, rows: Int)
    private let emit: @Sendable (TransportEvent) -> Void

    init(
        configuration: TransportConfiguration,
        initialSize: (cols: Int, rows: Int),
        emit: @escaping @Sendable (TransportEvent) -> Void
    ) {
        self.configuration = configuration
        self.initialSize = initialSize
        self.emit = emit
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Deliberately NOT allowing remote half-closure. With it on, a server
        // that closes its side (sshd killed, network dropped) leaves our
        // channel open and no event fires, so the session sat in CLOSE_WAIT
        // reporting "connected" forever. Leaving it off means the remote EOF
        // closes the channel and closeFuture fires.
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: false)
            .whenFailure { [emit] error in emit(.failed("\(error)")) }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: configuration.terminalType,
            terminalCharacterWidth: initialSize.cols,
            terminalRowHeight: initialSize.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)

        for (name, value) in configuration.environment {
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value),
                promise: nil
            )
        }

        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: false), promise: nil)
        emit(.connected)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty
        else { return }
        emit(.output(Data(bytes)))
    }

    /// Last-resort detection of a dead session: whichever way the channel
    /// goes away, the terminal hears about it rather than showing a stale
    /// "connected".
    func channelInactive(context: ChannelHandlerContext) {
        emit(.closed(nil))
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            emit(.closed(status.exitStatus))
        case let signal as SSHChannelRequestEvent.ExitSignal:
            emit(.failed("session closed: \(signal.signalName)"))
        case ChannelEvent.inputClosed:
            // The remote sent EOF. With half-closure enabled NIO reports it as
            // this event and deliberately leaves the channel open, so
            // closeFuture never completes — which is why a severed session used
            // to sit there claiming to be connected. Report it and tear the
            // channel down ourselves.
            emit(.closed(nil))
            context.close(promise: nil)
            // The remote sent EOF. With half-closure enabled NIO reports it as
            // this event and deliberately leaves the channel open, so
            // closeFuture never completes — which is why a severed session used
            // to sit there claiming to be connected. Report it and tear the
            // channel down ourselves.
            emit(.closed(nil))
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

/// Plain SSH transport built on SwiftNIO SSH. All `onEvent` callbacks are
/// delivered on the main queue.
public final class SSHTransport: TerminalTransport {
    public var onEvent: (@Sendable (TransportEvent) -> Void)?

    private var group: EventLoopGroup?
    private var connectionChannel: Channel?
    private var sessionChannel: Channel?
    private var sshHandler: NIOSSHHandler?
    private var reportedTerminal = false
    /// Set once disconnect() is called, so the resulting channel close is not
    /// reported as an unexpected drop.
    private var closing = false
    private let stateQueue = DispatchQueue(label: "app.cqutmux.transport.ssh")

    public init() {}

    private func emit(_ event: TransportEvent) {
        switch event {
        case .connected, .closed, .failed:
            stateQueue.sync { reportedTerminal = true }
        case .output:
            break
        }
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }

    public func connect(_ configuration: TransportConfiguration, cols: Int, rows: Int) {
        // Clear the "already reported" latch for this attempt. Without this a
        // later unexpected drop would find the flag still set from the
        // previous .connected and stay silent, leaving the UI stuck on
        // "connected" with a dead socket.
        stateQueue.sync {
            self.reportedTerminal = false
            self.closing = false
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        stateQueue.sync { self.group = group }

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    let sshHandler = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: CredentialAuthDelegate(
                                    username: configuration.username,
                                    credential: configuration.credential
                                ),
                                serverAuthDelegate: AcceptAllHostKeysDelegate()
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                    try channel.pipeline.syncOperations.addHandler(
                        ErrorHandler { [weak self] error in
                            self?.emit(.failed("\(error)"))
                        }
                    )
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            // Keep the TCP connection full-duplex: if the server closes, NIO
            // must close our side and fire closeFuture. With half-closure on,
            // a lost server left the socket in CLOSE_WAIT and the session
            // reported "connected" indefinitely.
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: false)

        bootstrap.connect(host: configuration.host, port: configuration.port).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.emit(.failed("\(error)"))
                self.shutdownGroup()
            case .success(let channel):
                self.stateQueue.sync { self.connectionChannel = channel }
                channel.closeFuture.whenComplete { [weak self] _ in
                    guard let self else { return }
                    // A close we did not ask for ends the session however far
                    // it got. Without this the socket can die quietly and the
                    // UI keeps claiming "connected". `closing` is a one-way
                    // latch set by disconnect(), so a user-initiated teardown
                    // stays silent.
                    if !self.stateQueue.sync(execute: { self.closing }) {
                        self.emit(.failed("connection closed"))
                    }
                }
                self.openSession(on: channel, configuration: configuration, cols: cols, rows: rows)
            }
        }
    }

    private func openSession(
        on channel: Channel,
        configuration: TransportConfiguration,
        cols: Int,
        rows: Int
    ) {
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.emit(.failed("\(error)"))
            case .success(let sshHandler):
                self.stateQueue.sync { self.sshHandler = sshHandler }
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .session) { [weak self] childChannel, channelType in
                    guard let self, channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(SSHTransportError.unexpectedChannelType)
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        let sync = childChannel.pipeline.syncOperations
                        try sync.addHandler(
                            ShellChannelHandler(
                                configuration: configuration,
                                initialSize: (cols, rows),
                                emit: { [weak self] event in self?.emit(event) }
                            )
                        )
                        try sync.addHandler(
                            ErrorHandler { [weak self] error in self?.emit(.failed("\(error)")) }
                        )
                    }
                }

                promise.futureResult.whenComplete { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.emit(.failed("\(error)"))
                    case .success(let childChannel):
                        self.stateQueue.sync { self.sessionChannel = childChannel }
                        self.resize(cols: cols, rows: rows)
                    }
                }
            }
        }
    }

    public func send(_ data: Data) {
        let channel = stateQueue.sync { sessionChannel }
        guard let channel, !data.isEmpty else { return }
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let channel = stateQueue.sync { sessionChannel }
        guard let channel else { return }
        channel.eventLoop.execute {
            channel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.WindowChangeRequest(
                    terminalCharacterWidth: cols,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0
                ),
                promise: nil
            )
        }
    }

    /// Opens a `direct-tcpip` channel through the SSH connection to `host:port`
/// as seen from the server. Used to reach the host's loopback gateway
/// (`127.0.0.1:24543`) without exposing it to the network.
    public func forward(
        remoteHost: String,
        remotePort: Int,
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) -> ForwardedSocket? {
        guard let handler = stateQueue.sync(execute: { sshHandler }),
              let channel = stateQueue.sync(execute: { connectionChannel })
        else { return nil }

        let socket = ForwardedSocket(onData: onData, onClose: onClose)
        channel.eventLoop.execute {
            let type = SSHChannelType.directTCPIP(
                .init(
                    targetHost: remoteHost,
                    targetPort: remotePort,
                    originatorAddress: try! SocketAddress(ipAddress: "127.0.0.1", port: 0)
                )
            )
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            handler.createChannel(promise, channelType: type) { child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(
                        ForwardedChannelHandler(onData: onData, onClose: onClose)
                    )
                }
            }
            promise.futureResult.whenComplete { result in
                switch result {
                case .success(let child): socket.attach(child)
                case .failure: socket.fail()
                }
            }
        }
        return socket
    }

    public func disconnect() {
        stateQueue.sync { self.closing = true }
        let session = stateQueue.sync { () -> Channel? in
            let s = sessionChannel
            sessionChannel = nil
            return s
        }
        session?.close(promise: nil)

        let connection = stateQueue.sync { () -> Channel? in
            let c = connectionChannel
            connectionChannel = nil
            return c
        }
        if let connection {
            connection.closeFuture.whenComplete { [weak self] _ in self?.shutdownGroup() }
            connection.close(promise: nil)
        } else {
            shutdownGroup()
        }
    }

    private func shutdownGroup() {
        let group = stateQueue.sync { () -> EventLoopGroup? in
            let g = self.group
            self.group = nil
            return g
        }
        group?.shutdownGracefully { _ in }
    }
}