import Foundation

// The client-marker rules, checked without a simulator.
//
// `IntegrationSettings` reads `UserDefaults.standard`, so each case starts from
// a cleared key rather than trusting whatever the machine running this has.

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)")
    }
}

let key = "integrations.exportClientEnv"

func settings(exporting: Bool?) -> IntegrationSettings {
    let defaults = UserDefaults.standard
    if let exporting {
        defaults.set(exporting, forKey: key)
    } else {
        defaults.removeObject(forKey: key)
    }
    return IntegrationSettings()
}

// MARK: - Off is the default, and off means silence

// The default is load-bearing: it is the difference between an upgrade that
// changes nothing on the host and one that starts setting variables in every
// session. There is no migration that could fix getting this wrong.
let fresh = settings(exporting: nil)
check(fresh.exportClientEnv == false, "the marker is off on a fresh install")
check(fresh.shellExportLine == nil, "nothing is typed into the session when it is off")
check(fresh.environment.isEmpty, "the transport carries nothing when it is off")

let off = settings(exporting: false)
check(off.shellExportLine == nil, "an explicitly disabled marker still types nothing")

// MARK: - On is one line, and the line is exactly this

let on = settings(exporting: true)
check(on.exportClientEnv == true, "the toggle round-trips through UserDefaults")

let line = on.shellExportLine
check(line != nil, "turning it on produces a line to type")
check(
    line == "export \(IntegrationSettings.variable)=1",
    "the line is `export CQUTMUX_CLIENT=1` (got: \(line ?? "nil"))"
)
check(
    IntegrationSettings.variable == "CQUTMUX_CLIENT",
    "the variable is named CQUTMUX_CLIENT"
)

// The line goes into a shell the host chose, so it has to be valid in the
// lowest common denominator. `export NAME=1` is; `export -- NAME=1` is not
// (dash's `export` takes no options), and the `--` is the tempting addition.
check(!(line ?? "").contains("--"), "the line does not use `export --`, which dash rejects")

// One line, not several: it is joined with the startup command by newline, and a
// marker containing its own newline would silently turn into two commands.
check(!(line ?? "").contains("\n"), "the line is a single line")
check(!(line ?? "").hasSuffix(" "), "the line has no trailing space to swallow")

let env = on.environment
check(env.count == 1, "exactly one variable is exported (got \(env.count))")
check(env[IntegrationSettings.variable] == "1", "the exported value is 1")

// MARK: - Persistence

check(
    settings(exporting: true).shellExportLine != nil,
    "the setting survives a fresh read"
)

// MARK: - Reset

UserDefaults.standard.removeObject(forKey: key)

if failures > 0 {
    print("\nINTEGRATIONS_FAIL  (\(failures) failed)")
    exit(1)
}
print("\nINTEGRATIONS_PASS")