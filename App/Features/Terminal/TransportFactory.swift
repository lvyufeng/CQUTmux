import CQUTTransport
import CQUTMosh
import CQUTET

/// Chooses the transport a host actually connects with.
///
/// All four kinds are now real. SSH is the byte pipe; Mosh is the state-sync
/// client that rides on an SSH session to start `mosh-server`; ET does the same
/// for `etterminal` over TCP, for networks that block mosh's UDP. `auto` is
/// Moshi's own order — mosh, then ET, then SSH — which matters because the three
/// fail for different reasons: mosh needs UDP and a mosh-server, ET needs TCP
/// and an etterminal, SSH needs only sshd.
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
            return .success(et(configuration: configuration, host: host))

        case .auto:
            // Moshi's order is mosh, then ET, then SSH. AutoTransport takes the
            // first two; its own fallback is what makes the third.
            return .success(AutoTransport(
                primary: mosh(configuration: configuration, host: host),
                fallback: et(configuration: configuration, host: host)
            ))
        }
    }

    /// ET is mosh's complement rather than its alternative: same shape of
    /// bootstrap over SSH, different protocol underneath, and it works on the
    /// networks where mosh's UDP is blocked.
    private static func et(
        configuration: TransportConfiguration,
        host: Host
    ) -> ETTransport {
        let launcher = SSHETLauncher(configuration: configuration)
        let transport = ETTransport()
        transport.launcher = launcher
        return transport
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