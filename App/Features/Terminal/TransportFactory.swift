import CQUTTransport
import CQUTMosh

/// Chooses the transport a host actually connects with.
///
/// The form offers four kinds, but only some are implemented: SSH is the
/// byte-pipe client, and Mosh is the state-sync client that rides on an SSH
/// session to start `mosh-server`. ET is not implemented, and `auto` means
/// "the best available", which today is mosh (what the user asked for, when the
/// host runs it) falling back to SSH.
enum TransportFactory {
    /// Builds the transport for `kind`, or reports why it cannot be built.
    ///
    /// - `host` and `configuration` describe the same machine: the
    ///   configuration is what the transport dials, the host is what the form
    ///   collected. Mosh needs both — the configuration to open SSH, the host to
    ///   know whether the user asked for a specific session command.
    static func make(
        kind: TransportKind,
        configuration: TransportConfiguration,
        host: Host
    ) -> Result<TerminalTransport, TransportUnavailable> {
        switch kind {
        case .ssh:
            return .success(SSHTransport())

        case .mosh:
            return .success(mosh(configuration: configuration, host: host))

        case .et:
            // Eternal Terminal is a different protocol on its own TCP port; it
            // is not built here, and silently running SSH instead would give the
            // user a session that quietly ignores what they picked.
            return .failure(TransportUnavailable(reason: "ET is not available in this build."))

        case .auto:
            // Moshi's order is mosh, then ET, then SSH. Without ET, that is
            // mosh with an SSH fallback.
            return .success(AutoTransport(
                primary: mosh(configuration: configuration, host: host),
                fallback: SSHTransport()
            ))
        }
    }

    private static func mosh(
        configuration: TransportConfiguration,
        host: Host
    ) -> MoshTransport {
        let launcher = SSHMoshLauncher(
            configuration: configuration,
            sessionCommand: host.sessionCommand.isEmpty ? nil : host.sessionCommand
        )
        launcher.portRange = host.moshPortRange
        let transport = MoshTransport()
        transport.launcher = launcher
        return transport
    }
}