import Foundation
import CQUTTransport

/// Starts `etterminal` on the host over an SSH session, for `ETTransport`.
///
/// The protocol is deliberately close to `SSHMoshLauncher`: run one command on
/// the host, read one line of its output, and hand the result to the transport.
/// The differences are ET's, not ours:
///
///   - `etterminal` is a *daemon launcher*, not a server. It starts `etserver`
///     if none is listening, asks it for a session, prints the credentials, and
///     forks. So this returns as soon as that line arrives.
///   - The credentials come *from* the server, not from us. `et`'s own client
///     sends a placeholder id and reads the real pair back; doing the same means
///     the app never has to invent a key format.
///   - ET then speaks TCP to the host on its own port, so — unlike mosh — the
///     connection is not on a forwarded or unusual channel. The SSH session is
///     only the bootstrap and is released as soon as the handshake is done.
public final class SSHETLauncher: ETLauncher, @unchecked Sendable {
    private let configuration: TransportConfiguration
    private let transport = SSHTransport()
    private let lock = NSLock()
    private var connected = false

    /// Port `etserver` listens on. ET's default is 2022.
    public var serverPort: Int = 2022

    /// Path to `etterminal` on the host, resolved once.
    private var serverPath: String?
    /// TERM to report to the server. Only affects the remote shell's own termcap.
    private var term: String = "xterm-256color"

    public init(configuration: TransportConfiguration) {
        self.configuration = configuration
    }

    public func startETSession(cols: Int, rows: Int) async throws -> ETEndpoint {
        try await ensureConnected()

        let etterminalPath: String
        if let cached = lock.withLock({ serverPath }) {
            etterminalPath = cached
        } else {
            guard let found = await transport.locate("etterminal"), !found.isEmpty else {
                throw ETLaunchError.notInstalled
            }
            lock.withLock { serverPath = found }
            etterminalPath = found
        }

        // etterminal is a *client* of the daemon, not a launcher for it: with
        // no etserver listening it fails with "The Eternal Terminal daemon is
        // not running". ET's stock `et` never hits this because it drives the
        // daemon's own startup over SSH through a fifo, so the app has to do
        // the equivalent itself.
        //
        // Starting it unconditionally is safe: a second etserver finds the port
        // taken, gives up, and exits without disturbing the first. That is
        // cheaper and more honest than probing, which would need a liveness
        // test that a half-dead daemon could pass.
        try await ensureServerRunning(etterminalPath: etterminalPath)

        // The credentials are a placeholder on purpose. ET's client sends
        // "XXX" followed by random characters, and a server that mints its own
        // keys replaces the whole pair — which is what the IDPASSKEY line below
        // reports. Sending a real-looking key here would work only against
        // servers that do not mint one, and would hide the ones that do.
        let placeholder = "XXX" + Self.randomAlphaNum(13)
        let stubPasskey = Self.randomAlphaNum(32)
        let stdinLine = "\(placeholder)/\(stubPasskey)_\(term)"

        // --serverfifo is deliberately not passed. etterminal finds the
        // running server's FIFO on its own (~/.local/share/etserver/...), which
        // is also how ET's own client reaches a server the user started by hand.
        let port = lock.withLock { serverPort }
        let command = ["printf", "%s\\n", stdinLine.shellQuoted, "|", etterminalPath]
            .joined(separator: " ")

        // ET's own client waits for the IDPASSKEY line inside a 15-second
        // window; this gives it a little more, because the first call here may
        // also be starting etserver.
        guard let result = await transport.run(command, timeout: 30) else {
            throw ETLaunchError.badBanner("etterminal produced no output")
        }
        guard var endpoint = try ETEndpoint.parse(banner: result.text) else {
            throw ETLaunchError.badBanner(result.text)
        }
        // etterminal prints only the credentials, so the address comes from how
        // the host was reached — the same address the SSH connection used, which
        // by construction the phone can reach.
        endpoint.host = configuration.host
        endpoint.port = port

        // The bootstrap is finished: ET now holds its own TCP connection, and
        // leaving this one open would be a second live connection to the host
        // doing nothing.
        stop()

        return endpoint
    }

    /// Starts `etserver` if it is not already up.
    ///
    /// `--daemon` is what makes this usable over a command channel: the process
    /// detaches immediately, so the SSH command returns instead of holding the
    /// channel for the life of the daemon.
    ///
    /// `--pidfile` is not optional in practice. Left to its default
    /// (/var/run/etserver.pid) the daemon cannot write the file and aborts, and
    /// because it has already forked the failure is invisible from here — the
    /// command reports success while nothing is listening.
    private func ensureServerRunning(etterminalPath: String) async throws {
        let port = lock.withLock { serverPort }
        // etserver lives beside etterminal; the login shell's PATH may not
        // contain either, and locate() found the one we have.
        let directory = (etterminalPath as NSString).deletingLastPathComponent
        let etserver = directory.isEmpty ? "etserver" : "\(directory)/etserver"

        let pidfile = "/tmp/.cqutmux-etserver-\(getuid()).pid"
        let logdir = "/tmp/.cqutmux-etserver-\(getuid())"
        let command = [etserver, "--daemon", "--port", String(port),
                       "--pidfile", pidfile, "--logdir", logdir].joined(separator: " ")

        // No error is raised on failure, and none can be: a refusal here means
        // a server is already listening, which is the outcome wanted. If the
        // start genuinely failed, the etterminal call right after says so.
        _ = await transport.run(command, timeout: 15)
    }

    private func ensureConnected() async throws {
        if lock.withLock({ connected }) { return }

        transport.connect(configuration, cols: 80, rows: 24)
        for _ in 0..<60 {
            if transport.hasActiveSession { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard transport.hasActiveSession else {
            throw ETLaunchError.badBanner("no SSH session to start etterminal on")
        }
        lock.withLock { connected = true }
    }

    public func stop() {
        transport.disconnect()
        lock.withLock { connected = false }
    }

    /// ET's own client generates credentials from an alphanumeric alphabet, and
    /// the server's parser expects that shape.
    private static func randomAlphaNum(_ count: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<count).map { _ in alphabet.randomElement()! })
    }
}