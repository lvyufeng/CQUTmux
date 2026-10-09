import Foundation

/// What a host's gateway is doing, as the status dot beside it shows.
///
/// Five states rather than up/down because the three failures need different
/// things done about them, and a dot that says "not working" for all of them
/// sends the user to the wrong one. The wording is the fix, not the diagnosis:
/// each case carries the command that resolves it, because the person looking
/// at a red dot on a phone is not going to work out which of these it is.
enum GatewayState: Equatable {
    /// The probe has not run yet, or is running.
    case unknown
    /// Answered on the port the app is configured for.
    case running(version: String?, pending: Int)
    /// Something is listening and answering, but it is not this gateway — a
    /// stale process from an older version, or another service on the port.
    case update(version: String?)
    /// Nothing on the configured port, but *something* is on the default one:
    /// a gateway started with the default port while the app expects another.
    case wrongPort(found: Int)
    /// Nothing anywhere, but the tool is on the host.
    case notRunning
    /// The tool is not on the host at all.
    case notInstalled

    /// Whether the gateway answered where the app expected it to. A computed
    /// property rather than `== .running` at the call site, because `.running`
    /// carries a value and an equality check against an enum case with
    /// associated values has to spell them out.
    var isUp: Bool {
        if case .running = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .unknown:
            return "Checking"
        case .running:
            return "Running"
        case .update(let version):
            return version.map { "Update \($0)" } ?? "Wrong version"
        case .wrongPort(let port):
            return "Port \(port)"
        case .notRunning:
            return "Not running"
        case .notInstalled:
            return "Not installed"
        }
    }

    /// The one thing to type, or nil when there is nothing to fix here.
    var fix: String? {
        switch self {
        case .unknown, .running:
            return nil
        case .update:
            // No npm package exists: the gateway runs from a checkout of this
            // repo. A command the user cannot run is worse than no command,
            // because it is followed and then believed when it does nothing.
            return "git pull  ·  then take the running gateway down and up again"
        case .wrongPort(let port):
            return "cqutmux serve --port \(port)  ·  or set the host's port to it"
        case .notRunning:
            return "cqutmux serve"
        case .notInstalled:
            return "cqutmux install  ·  from a checkout of this repo, on the host"
        }
    }

    /// A longer explanation for the sheet, which has room for it.
    var detail: String {
        switch self {
        case .unknown:
            return "Asking the host whether its gateway is up."
        case .running(let version, let pending):
            let version = version.map { "Gateway \($0)." } ?? "Gateway running."
            return pending > 0
                ? "\(version) \(pending) approval(s) waiting."
                : "\(version) Nothing waiting."
        case .update(let version):
            let seen = version.map { " It reports \($0)." } ?? " It reports no version."
            return "Something is answering on this host's gateway port, but it is not "
                + "a version the app recognises.\(seen) An older gateway may not know "
                + "routes this app uses."
        case .wrongPort(let port):
            return "Nothing on the port this host is set to, but a gateway answered on "
                + "\(port). The app is looking where the gateway is not."
        case .notRunning:
            return "The tool is installed on the host but no gateway is serving. "
                + "Nothing the app asks for will answer until one is started."
        case .notInstalled:
            return "The host has no cqutmux-hook. Sessions still work; the Inbox, "
                + "Code and Jump To tabs need it."
        }
    }
}
/// The part of the probe that decides, kept apart from the part that connects.
///
/// `defaultPort`, `probeScript` and `interpret` are pure: no transport, no host
/// objects, no app settings. That is deliberate — the five states are where a
/// mistake shows the user the *wrong fix*, and a wrong fix is worse than no
/// answer, so this half is written to be run directly by a check rather than
/// only through a simulator.
enum GatewayStatus {
    /// The gateway's own default, which is what a `cqutmux serve` with no
    /// arguments listens on. A host whose port is set to something else and has
    /// a gateway on this one is the wrong-port case.
    static let defaultPort = 24543

    /// A shell script that prints one `key=value` line per fact.
    ///
    /// `command -v` rather than a hardcoded path: the tool installs wherever
    /// npm or Homebrew put it, and the login shell is not sourced here for the
    /// same reason `SSHTransport.locate` does not source it — a stray `ssh-add`
    /// in an rc file can hang the channel.
    static func probeScript(ports: [Int]) -> String {
        let probes = ports.map { port in
            // No `|| echo 000`: curl already prints `000` for a connection it
            // could not make, and appending another one would make the value
            // `000000` — which is not `"000"`, so every dead port would read as
            // *answering* and every host would show a green dot.
            "printf 'port_\(port)=%s\\n' \"$(curl -s -m 4 -o /dev/null -w '%{http_code}' "
            + "http://127.0.0.1:\(port)/health 2>/dev/null)\""
        }.joined(separator: "; ")
        return """
        printf 'tool=%s\\n' "$(command -v cqutmux || command -v cqutmux-hook || echo none)"; \
        printf 'version=%s\\n' "$(cqutmux version 2>/dev/null | sed 's/^cqutmux //' || echo none)"; \
        \(probes)
        """
    }

    /// Turns the probe's `key=value` lines into a state.
    ///
    /// Pure and static so the mapping can be checked without a host: this is
    /// where the five states are actually decided, and a mistake here shows the
    /// wrong fix.
    static func interpret(_ text: String, configuredPort: Int, exitCode: Int?) -> GatewayState {
        var facts: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            facts[parts[0].trimmingCharacters(in: .whitespaces)] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }

        let tool = facts["tool"] ?? "none"
        let version = facts["version"].flatMap { $0 == "none" || $0.isEmpty ? nil : $0 }

        // Only a real HTTP status counts. curl writes `000` when it could not
        // connect, and anything that is not a three-digit status — empty,
        // doubled, or garbage — means the probe's output was not what this
        // expects. Treating those as "answering" is the failure that matters:
        // it shows a green dot for a host with nothing on the port at all, so
        // the one thing this screen exists to catch is the one thing it hides.
        func status(_ port: Int) -> Int? {
            guard let value = facts["port_\(port)"], value.count == 3,
                  let code = Int(value), code >= 100, code <= 599, code != 0
            else { return nil }
            return code
        }

        func answering(_ port: Int) -> Bool { status(port) != nil }

        if answering(configuredPort) {
            // Reachable on the right port. A gateway too old to know a route
            // answers 404 where a current one answers 200, and that is the
            // "update" case rather than "running".
            if status(configuredPort) == 404 {
                return .update(version: version)
            }
            return .running(version: version, pending: 0)
        }

        // A *different* gateway on the default port, when this host is set
        // elsewhere, is the wrong-port case — the app is looking where the
        // gateway is not.
        if configuredPort != GatewayStatus.defaultPort, answering(defaultPort) {
            return .wrongPort(found: defaultPort)
        }

        if tool != "none" { return .notRunning }
        return .notInstalled
    }
}
