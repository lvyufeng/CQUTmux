import Foundation

/// Settings → Integrations → Shell, in Moshi's grouping.
///
/// Only one option lives here, and it is here rather than under Appearance
/// because it is the *host's* behaviour it changes, not the app's: a shell on
/// the far machine can read the marker and adapt.
///
/// Moshi gates this behind Pro; we do not, and that is a deliberate divergence
/// rather than an oversight. Reproducing a paywall would be reproducing a
/// business model, not a feature.
@Observable
final class IntegrationSettings {
    private static let markerKey = "integrations.exportClientEnv"

    /// Export `CQUTMUX_CLIENT=1` into every session this app opens.
    var exportClientEnv: Bool {
        didSet { UserDefaults.standard.set(exportClientEnv, forKey: Self.markerKey) }
    }

    init() {
        exportClientEnv = UserDefaults.standard.bool(forKey: Self.markerKey)
    }

    /// The marker and its value, or nothing when the toggle is off.
    var environment: [String: String] {
        exportClientEnv ? [Self.variable: "1"] : [:]
    }

    /// The line to type into a live session, or nothing when the toggle is off.
    ///
    /// An `export` rather than an SSH environment request, and that is forced
    /// rather than chosen: sshd drops environment requests unless its own
    /// `AcceptEnv` names the variable, and a stock `sshd_config` names none —
    /// verified here against a real sshd, where the request is answered and the
    /// value still arrives unset. Moshi's own documentation describes the same
    /// mechanism for the SSH path ("an injected `export` at shell start"), which
    /// is the tell that this is the protocol's shape and not our workaround.
    ///
    /// `export` with no `--`: `/bin/sh`, bash and zsh all take it, and this line
    /// has to be valid in whatever shell the host happens to run.
    var shellExportLine: String? {
        guard exportClientEnv else { return nil }
        return "export \(Self.variable)=1"
    }

    static let variable = "CQUTMUX_CLIENT"
}
