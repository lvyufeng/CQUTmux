import Foundation
import CQUTTransport

/// Starts `mosh-server` on the host over an SSH session, for `MoshTransport`.
///
/// Mosh is a client/server protocol: the host runs `mosh-server`, which opens
/// a UDP port and prints a one-time key. Getting that server started is the
/// one thing the phone cannot do without a host-side execution channel, and
/// the SSH connection already open is exactly that.
///
/// The SSH session stays up for the life of the mosh session. It is not
/// carrying the terminal — it is how `mosh-server` was started and how the app
/// can stop it again — but dropping it would leave an orphan server.
public final class SSHMoshLauncher: MoshServerLauncher, @unchecked Sendable {
    private let configuration: TransportConfiguration
    private let transport = SSHTransport()
    private let lock = NSLock()
    private var connected = false

    /// What the host form's "Mosh UDP port range" field collects, e.g.
    /// `60000:61000`. Passed to `mosh-server -p`. Worth setting behind a
    /// firewall: without it the server picks from the ephemeral range and the
    /// UDP port the client needs is the one nothing opened.
    public var portRange: String?

    /// Command the mosh session runs. Defaults to the host's login shell.
    private var sessionCommand: String?
    /// Path to `mosh-server`, resolved once on the host.
    private var serverPath: String?

    public init(configuration: TransportConfiguration, sessionCommand: String? = nil) {
        self.configuration = configuration
        self.sessionCommand = sessionCommand
    }

    public func startMoshServer(cols: Int, rows: Int) async throws -> MoshEndpoint {
        try await ensureConnected()

        // Resolve the path once: a GUI app's PATH is not the host's, and
        // `mosh-server` is frequently in a directory the login shell only adds
        // to PATH via its rc files. Asking the host is the only reliable way.
        let path: String
        if let cached = lock.withLock({ serverPath }) {
            path = cached
        } else {
            guard let found = await transport.locate("mosh-server"), !found.isEmpty else {
                throw MoshLaunchError.serverNotInstalled
            }
            lock.withLock { serverPath = found }
            path = found
        }

        // -l LANG: mosh-server refuses to start unless the environment says the
        // terminal is UTF-8, and a non-interactive SSH command inherits settings
        // the host may not have. Passed explicitly rather than assumed, because
        // the failure is a hard exit with a long explanation.
        //
        // -c 256 so mosh has indexed colour to give the terminal.
        //
        // `-s` matters more than it looks: mosh-server otherwise stays in the
        // foreground for the life of the session, which would mean holding this
        // SSH channel open forever. Detached, it prints its banner and exits, so
        // the SSH session is only needed to start it.
        //
        // Every other variable the configuration carries goes in as its own
        // `-l`. It has to: the SSH channel's own environment requests reach the
        // bootstrap shell, not mosh-server, and mosh-server builds the session's
        // environment from its own `-l` list. A variable we only sent over the
        // channel would therefore be missing from the one shell the user
        // actually types into — which is the whole point of exporting it.
        var args = ["-l", "LANG=en_US.UTF-8", "-c", "256", "-s"]
        for (name, value) in configuration.environment.sorted(by: { $0.key < $1.key }) {
            // LANG is already above, and repeating it would only risk two
            // different values for one name.
            guard name != "LANG" else { continue }
            args += ["-l", "\(name)=\(value)".shellQuoted]
        }
        if let portRange = lock.withLock({ portRange }), !portRange.isEmpty {
            args += ["-p", portRange.shellQuoted]
        }

        // mosh-server execs this argv directly — there is no shell — so a
        // multi-word command like `tmux new -A -s cqutmux` has to be handed to
        // one explicitly.
        let run = sessionCommand ?? "$SHELL -l"
        let command = ([path, "new"] + args + ["--", "sh", "-c", run.shellQuoted])
            .joined(separator: " ")

        guard let result = await transport.run(command, timeout: 25) else {
            throw MoshLaunchError.badBanner("mosh-server produced no output")
        }
        var endpoint = try MoshEndpoint.parse(banner: result.text)
        // mosh-server prints only the port and key, so the address comes from
        // how we reached the host in the first place. This is the same address
        // the SSH connection used, which by construction the phone can reach.
        //
        // Note this means the UDP port is on the network, not tunnelled —
        // SSH's port forwarding is TCP-only. That is how mosh works everywhere:
        // the traffic is AES-128-OCB3 under a single-use key, so the exposed
        // surface is the port and nothing else.
        endpoint.host = configuration.host

        // The launcher's work is done. mosh-server detached itself, the terminal
        // will be carried over UDP, and the window size goes to the server over
        // mosh's own protocol rather than through an SSH pty — so keeping this
        // session open would be a second live connection to the host doing
        // nothing. Closing it also means the app has exactly one connection per
        // host, which is what a user watching a jump host would expect.
        stop()

        return endpoint
    }

    private func ensureConnected() async throws {
        if lock.withLock({ connected }) { return }

        transport.connect(configuration, cols: 80, rows: 24)
        // Readiness is signalled through the event stream; poll the handshake
        // rather than inventing a second signal. Bounded, so a host that
        // refuses us fails instead of hanging.
        for _ in 0..<60 {
            if transport.hasActiveSession { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard transport.hasActiveSession else {
            throw MoshLaunchError.badBanner("no SSH session to start mosh-server on")
        }
        lock.withLock { connected = true }
    }

    public func stop() {
        transport.disconnect()
        lock.withLock { connected = false }
    }
}