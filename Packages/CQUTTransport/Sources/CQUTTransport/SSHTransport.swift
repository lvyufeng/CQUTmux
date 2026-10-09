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

        // Offered, but do not expect sshd to honour it: the request is only
        // applied for names the server's own `AcceptEnv` lists, and a stock
        // `sshd_config` lists none. Verified against a real sshd here — the
        // request is acknowledged and the variable still arrives unset, and
        // OpenSSH's own client behaves identically with `SetEnv`. Sending it
        // anyway costs nothing and covers hosts that do configure `AcceptEnv`;
        // anything that must actually arrive goes in as an export typed into
        // the session (see `IntegrationSettings.shellExportLine`), or as a
        // `-l` argument to a launcher that builds its own environment.
        for (name, value) in configuration.environment {
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value),
                promise: nil
            )
        }

        // The agent request goes before the shell, which is where OpenSSH's
        // own client puts it and appears to be the only ordering sshd prepares
        // the agent socket for. Sent after the shell request it is still
        // acknowledged — `server_input_channel_req … reply 0` — but sshd never
        // creates the socket, so SSH_AUTH_SOCK arrives unset and the failure
        // looks like a server that does not support forwarding at all.
        if configuration.forwardAgent {
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.AgentForwardingRequest(wantReply: false),
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
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

/// Collects everything a one-shot exec channel emits.
private final class ExecCollector: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let lock = NSLock()
    private var buffer = Data()
    private var code: Int?

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    var exitCode: Int? {
        lock.lock(); defer { lock.unlock() }
        return code
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = payload.data,
              let chunk = bytes.readBytes(length: bytes.readableBytes)
        else { return }
        lock.lock()
        buffer.append(contentsOf: chunk)
        lock.unlock()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            lock.lock()
            code = status.exitStatus
            lock.unlock()
        }
        context.fireUserInboundEventTriggered(event)
    }
}

public extension String {
    /// Single-quotes for a POSIX shell, closing and reopening around any
    /// embedded quote so a path with a space or an apostrophe cannot break out.
    /// Public because callers that build remote commands out of user input —
    /// mosh's port range, for one — need it too.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Plain SSH transport built on SwiftNIO SSH. All `onEvent` callbacks are
/// delivered on the main queue.
public final class SSHTransport: TerminalTransport {
    public var onEvent: (@Sendable (TransportEvent) -> Void)?

    /// True once the SSH handshake finished and a handler exists. Callers that
    /// need to run a command before the shell channel is up (mosh-server
    /// launch) wait on this rather than inventing a second readiness signal.
    public var hasActiveSession: Bool {
        stateQueue.sync { sshHandler != nil }
    }

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

        if let jump = configuration.jumpHost {
            connectViaJumpHost(jump, configuration: configuration, cols: cols, rows: rows)
        } else {
            connectDirect(configuration: configuration, cols: cols, rows: rows)
        }
    }

    /// The common case: a socket straight to the target.
    private func connectDirect(configuration: TransportConfiguration, cols: Int, rows: Int) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        stateQueue.sync { self.group = group }

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    try self?.installSSH(on: channel, configuration: configuration)
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
                self.adopt(connectionChannel: channel) {
                    self.openSession(on: channel, configuration: configuration, cols: cols, rows: rows)
                }
            }
        }
    }

    /// Two hops: SSH to the jump host, then a `direct-tcpip` channel out of it
    /// to the target, and the target's SSH connection runs inside that.
    ///
    /// The group's single event loop is deliberate — every channel here shares
    /// it, so the target's `NIOSSHHandler` and the jump's pipeline that feeds
    /// it are never touched from two threads.
    private func connectViaJumpHost(_ jump: JumpHost, configuration: TransportConfiguration, cols: Int, rows: Int) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        stateQueue.sync { self.group = group }

        let jumpAuth = CredentialAuthDelegate(username: jump.username, credential: jump.credential)
        let targetAuth = CredentialAuthDelegate(
            username: configuration.username,
            credential: configuration.credential
        )

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(
                        role: .client(
                            .init(userAuthDelegate: jumpAuth, serverAuthDelegate: AcceptAllHostKeysDelegate())
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: false)

        bootstrap.connect(host: jump.host, port: jump.port).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.emit(.failed("jump host \(jump.host): \(error)"))
                self.shutdownGroup()

            case .success(let jumpChannel):
                jumpChannel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] handlerResult in
                    guard let self else { return }
                    switch handlerResult {
                    case .failure(let error):
                        self.emit(.failed("jump host \(jump.host): \(error)"))
                        self.shutdownGroup()

                    case .success(let jumpHandler):
                        let promise = jumpChannel.eventLoop.makePromise(of: Channel.self)
                        jumpHandler.createChannel(promise, channelType: .directTCPIP(
                            .init(
                                targetHost: configuration.host,
                                targetPort: configuration.port,
                                originatorAddress: (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))
                                    ?? (try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
                            )
                        )) { child, _ in
                            child.eventLoop.makeCompletedFuture {
                                let sync = child.pipeline.syncOperations
                                // Order matters: the unwrapper must be innermost
                                // so it sees `ByteBuffer` on its way out, before
                                // the channel packs it into `SSHChannelData`.
                                try sync.addHandler(SSHDataToByteBufferHandler())
                                try sync.addHandler(ByteBufferToSSHDataHandler())
                                try self.installSSH(on: child, configuration: configuration, auth: targetAuth)
                            }
                        }

                        promise.futureResult.whenComplete { [weak self] channelResult in
                            guard let self else { return }
                            switch channelResult {
                            case .failure(let error):
                                self.emit(.failed("jump host could not reach \(configuration.host):\(configuration.port) — \(error)"))
                                self.shutdownGroup()
                            case .success(let targetChannel):
                                // Adopt the *jump* channel: it is the one that
                                // stops when the network goes, and the target
                                // channel's liveness is tied to the forward.
                                self.adopt(connectionChannel: jumpChannel, opening: targetChannel) {
                                    self.openSession(on: targetChannel, configuration: configuration, cols: cols, rows: rows)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Adds the client-side SSH stack to a channel. Used for both the direct
    /// socket and the forwarded channel a jump host hands us.
    private func installSSH(
        on channel: Channel,
        configuration: TransportConfiguration,
        auth: CredentialAuthDelegate? = nil
    ) throws {
        let delegate = auth ?? CredentialAuthDelegate(
            username: configuration.username,
            credential: configuration.credential
        )
        let sshHandler = NIOSSHHandler(
            role: .client(.init(userAuthDelegate: delegate, serverAuthDelegate: AcceptAllHostKeysDelegate())),
            allocator: channel.allocator,
            // Only channels the server opens to us are expected here, and the
            // only one we invite is the agent. The initializer is what makes
            // forwarding work at all: the request alone gets the server to
            // agree, but nothing happens until it can open a channel and find
            // an agent listening.
            inboundChildChannelInitializer: agentInitializer(configuration.agentSigner, configuration.credential)
        )
        let sync = channel.pipeline.syncOperations
        try sync.addHandler(sshHandler)
        try sync.addHandler(ErrorHandler { [weak self] error in self?.emit(.failed("\(error)")) })
    }

    /// Builds the handler for a channel the server opens back to us.
    ///
    /// Only the agent channel is ever invited, so an initializer that refuses
    /// anything else is the correct amount of code. Returning a failed future
    /// rather than nil means the server gets a proper channel-open failure
    /// instead of a hang.
    private func agentInitializer(
        _ signer: SSHAgent.Signer?,
        _ credential: SSHCredential
    ) -> @Sendable (Channel, SSHChannelType) -> EventLoopFuture<Void> {
        { child, channelType in
            guard case .authAgent = channelType else {
                return child.eventLoop.makeFailedFuture(SSHTransportError.unexpectedChannelType)
            }
            guard let signer, let identity = credential.agentIdentity else {
                // Asked for forwarding but there is no key to serve. Failing
                // the open is what makes `git` on the host say "permission
                // denied" rather than hanging on a channel nobody answers.
                return child.eventLoop.makeFailedFuture(SSHAgent.AgentError.noIdentity)
            }
            let handler = SSHAgentChannelHandler(agent: SSHAgent(identity: identity, sign: signer))
            return child.eventLoop.makeCompletedFuture {
                try child.pipeline.syncOperations.addHandler(handler)
            }
        }
    }

    /// Records the channel whose death ends the session and starts `opening`
    /// once the identity is ours. Split out so both connect paths report a
    /// drop the same way.
    private func adopt(
        connectionChannel channel: Channel,
        opening target: Channel? = nil,
        _ start: @escaping () -> Void
    ) {
        stateQueue.sync { self.connectionChannel = channel }
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            // A close we did not ask for ends the session however far it got.
            // Without this the socket can die quietly and the UI keeps claiming
            // "connected". `closing` is a one-way latch set by disconnect(), so
            // a user-initiated teardown stays silent.
            if !self.stateQueue.sync(execute: { self.closing }) {
                self.emit(.failed("connection closed"))
            }
            // Tear the forwarded side down too, or the jump host keeps the
            // `direct-tcpip` channel open for a target nobody is talking to.
            target?.close(promise: nil)
        }
        start()
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

    /// Looks up a command's absolute path on the host.
    ///
    /// iOS and macOS hold a GUI app's PATH to a bare minimum, so a remote
    /// `command -v` run over SSH is the only reliable way to learn whether a
    /// tool exists and where — needed before offering a transport that depends
    /// on a host-side program.
    public func locate(_ command: String) async -> String? {
        let probe = "command -v \(command.shellQuoted)"
        // Search the usual install directories explicitly before falling back
        // to a login shell. A login shell sources the user's rc files, which is
        // both slow and fragile — a single `ssh-add` or `nvm` line can stall it
        // past the timeout or print a banner over the answer — and it is only
        // being asked to do what this PATH already does. Prepending rather than
        // replacing matters: it keeps the user's own PATH as the tail, so a
        // tool they installed somewhere unusual is still found.
        let path = (
            ["$HOME/.local/bin", "$HOME/bin", "/home/linuxbrew/.linuxbrew/bin",
             "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin"]
            + ["$PATH"]
        ).joined(separator: ":")
        let fast = "PATH=\(path.shellQuoted) \(probe)"
        for candidate in [fast, "sh -lc \(probe.shellQuoted)", probe] {
            guard let output = await run(candidate, timeout: 15) else { continue }
            for line in output.text.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                // A path, not a shell complaint. Without this, "command not
                // found" and warnings from an rc file would be returned as the
                // program's path and only fail later, as a confusing exec error.
                if text.hasPrefix("/") { return text }
            }
        }
        return nil
    }

    /// The effect of running `command` over a one-shot SSH channel. A login
    /// command produces a small banner, so this is sized for that rather than
    /// for bulk output.
    public struct ExecResult: Sendable {
        public var text: String
        public var exitCode: Int?
    }

    public func run(_ command: String, timeout: TimeInterval = 20) async -> ExecResult? {
        guard let handler = stateQueue.sync(execute: { sshHandler }),
              let channel = stateQueue.sync(execute: { connectionChannel })
        else { return nil }

        let collector = ExecCollector()
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        channel.eventLoop.execute {
            handler.createChannel(promise, channelType: .session) { child, type in
                guard type == .session else {
                    return child.eventLoop.makeFailedFuture(SSHTransportError.unexpectedChannelType)
                }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(collector)
                }
            }
        }

        guard let child = try? await promise.futureResult.get() else { return nil }

        child.eventLoop.execute {
            child.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false),
                promise: nil
            )
        }

        // The channel closes when the remote command exits; the cap is only a
        // guard against a command that never does.
        _ = try? await child.closeFuture.get()
        _ = try? await Task.sleep(for: .milliseconds(1)) // let the last read land
        return ExecResult(text: collector.text, exitCode: collector.exitCode)
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