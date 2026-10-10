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
check(fresh.shellExportLines.isEmpty, "nothing is typed into the session when it is off")
check(fresh.environment.isEmpty, "the transport carries nothing when it is off")

let off = settings(exporting: false)
check(off.shellExportLines.isEmpty, "an explicitly disabled marker still types nothing")

// MARK: - On is one line, and the line is exactly this

let on = settings(exporting: true)
check(on.exportClientEnv == true, "the toggle round-trips through UserDefaults")

let lines = on.shellExportLines
check(lines.count == 1, "turning it on produces one line to type (got \(lines.count))")
let line = lines.first
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

// MARK: - The host locale

// Nothing is sent until a locale is chosen. This is the same rule as the
// marker's: an upgrade must not start setting variables on the host behind the
// user's back, and here the cost is concrete — a host without the named locale
// prints a `setlocale` warning before every command.
let noLocale = settings(exporting: nil)
check(noLocale.locale.isEmpty, "no locale is set on a fresh install")
check(noLocale.localeEnvironment.isEmpty, "and nothing locale-shaped is carried to the host")
check(noLocale.shellExportLines.isEmpty, "nor typed into the session")

UserDefaults.standard.set("en_US.UTF-8", forKey: "integrations.hostLocale")
let localised = IntegrationSettings()
check(localised.locale == "en_US.UTF-8", "a stored locale round-trips through UserDefaults")

// LANG and LC_ALL go together. Sending only LANG leaves a host whose
// /etc/profile sets its own LC_ALL ignoring the value we sent, and that host is
// exactly the one where a mis-set locale causes trouble.
let localeEnv = localised.localeEnvironment
check(localeEnv["LANG"] == "en_US.UTF-8", "the locale is exported as LANG")
check(localeEnv["LC_ALL"] == "en_US.UTF-8", "and as LC_ALL, which overrides a host's own")

let localeLines = localised.shellExportLines
check(localeLines.count == 2, "two locale lines are typed (got \(localeLines.count))")
check(localeLines.contains("export LANG=en_US.UTF-8"), "one sets LANG")
check(localeLines.contains("export LC_ALL=en_US.UTF-8"), "one sets LC_ALL")

// Both halves at once: the marker and the locale are independent settings that
// share one preamble, so turning both on must produce both, in an order where
// the later lines cannot be mistaken for part of an earlier value.
UserDefaults.standard.set(true, forKey: key)
let both = IntegrationSettings()
check(both.shellExportLines.count == 3, "marker plus locale is three lines")
check(both.shellExportLines.last == "export CQUTMUX_CLIENT=1", "the marker line comes last")
check(both.environment["CQUTMUX_CLIENT"] == "1", "and both reach the transport environment")
check(both.environment["LANG"] == "en_US.UTF-8", "LANG too")

// The environment carries the union, so a transport that only sends variables
// (mosh's `-l` list) gets the locale it needs to start at all.
check(both.environment.count == 3, "three variables go to the transport (got \(both.environment.count))")

// MARK: - Which locales are safe to send

// A locale name goes into a shell line unquoted, so it is restricted to the
// characters a locale name is made of. A value carrying a newline or a `;`
// would not set a variable — it would run a command.
func exportable(_ name: String) -> Bool { IntegrationSettings.isExportableLocale(name) }
check(exportable("en_US.UTF-8"), "en_US.UTF-8 is exportable")
check(exportable("C.UTF-8"), "C.UTF-8 is exportable")
check(exportable("de_DE.UTF-8@euro"), "a modifier locale is exportable")
check(exportable("en_US.utf8"), "the utf8 spelling is exportable")

check(!exportable(""), "an empty locale is not exportable")
check(!exportable("C"), "C is not a UTF-8 locale, and setting it would mojibake output")
check(!exportable("POSIX"), "POSIX is not either")
check(!exportable("en_US.ISO-8859-1"), "a non-UTF-8 encoding is not exportable")
check(!exportable("en_US.UTF-8\nrm -rf /"), "a locale with a newline is refused")
check(!exportable("en_US.UTF-8; rm -rf /"), "a locale with a semicolon is refused")
check(!exportable("$(whoami)"), "a locale with a command substitution is refused")

// And the gate is wired in, not decorative: a refused locale sends nothing at
// all rather than a partially-applied pair. The marker is turned back off first,
// so the only thing that could produce a line here is the locale.
UserDefaults.standard.set(false, forKey: key)
UserDefaults.standard.set("en_US.UTF-8; rm -rf /", forKey: "integrations.hostLocale")
let hostile = IntegrationSettings()
check(hostile.localeEnvironment.isEmpty, "a hostile locale is dropped, not sanitised into a line")
check(hostile.shellExportLines.isEmpty, "so nothing is typed for it")
UserDefaults.standard.removeObject(forKey: "integrations.hostLocale")

// MARK: - Persistence

check(
    settings(exporting: true).shellExportLines.isEmpty == false,
    "the setting survives a fresh read"
)

// MARK: - Reset

UserDefaults.standard.removeObject(forKey: key)
UserDefaults.standard.removeObject(forKey: "integrations.hostLocale")

if failures > 0 {
    print("\nINTEGRATIONS_FAIL  (\(failures) failed)")
    exit(1)
}
print("\nINTEGRATIONS_PASS")