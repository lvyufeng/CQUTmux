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
    private static let localeKey = "integrations.hostLocale"

    /// Export `CQUTMUX_CLIENT=1` into every session this app opens.
    var exportClientEnv: Bool {
        didSet { UserDefaults.standard.set(exportClientEnv, forKey: Self.markerKey) }
    }

    /// The locale both `LANG` and `LC_ALL` are set to on the host, or empty for
    /// "leave the host's own locale alone".
    ///
    /// A stored string rather than a picker, because which locales a machine has
    /// installed is the machine's business. `en_US.UTF-8` is on any Debian or
    /// macOS host, `C.UTF-8` is the one name every libc has, and a user with an
    /// unusual host knows what theirs is called.
    ///
    /// Empty by default, for the reason the marker is off by default: setting a
    /// locale on a host that does not have it installed makes every command
    /// print a `setlocale` warning, so defaulting this on would turn an upgrade
    /// into a regression on exactly the minimal hosts most likely to lack it.
    var locale: String {
        didSet { UserDefaults.standard.set(locale, forKey: Self.localeKey) }
    }

    init() {
        exportClientEnv = UserDefaults.standard.bool(forKey: Self.markerKey)
        locale = UserDefaults.standard.string(forKey: Self.localeKey) ?? ""
    }

    /// The locale offered in the field when none is set. Both ends need UTF-8,
    /// and a host with no `en_US.UTF-8` is rarer than one carrying no locale.
    static let suggestedLocale = "en_US.UTF-8"

    /// The marker and its value, or nothing when the toggle is off.
    var marker: [String: String] {
        exportClientEnv ? [Self.variable: "1"] : [:]
    }

    /// The locale variables carried to the host, or empty when the stored value
    /// is not a UTF-8 locale we can put in a shell line unquoted.
    ///
    /// Empty rather than "best effort" on purpose: `LC_ALL=C` would override
    /// every other locale setting and turn the terminal's UTF-8 output into
    /// mojibake — a setting that makes things worse is worse than one that does
    /// nothing, and this one would fail silently.
    var localeEnvironment: [String: String] {
        Self.localeVariables(for: locale)
    }

    /// Everything this app adds to a session's environment.
    var environment: [String: String] {
        marker.merging(localeEnvironment) { _, locale in locale }
    }

    /// The lines to type into a live session, or empty when there is nothing to
    /// set.
    ///
    /// An `export` rather than relying on the SSH environment request alone, and
    /// that is forced rather than chosen: sshd drops environment requests unless
    /// its own `AcceptEnv` names the variable, and a stock `sshd_config` names
    /// none — verified here against a real sshd, where the request is answered
    /// and the value still arrives unset. Moshi's own documentation describes
    /// the same mechanism for the SSH path ("an injected `export` at shell
    /// start"), which is the tell that this is the protocol's shape and not our
    /// workaround.
    ///
    /// `export` with no `--`: `/bin/sh`, bash and zsh all take it, and this line
    /// has to be valid in whatever shell the host happens to run. `LC_ALL` goes
    /// alongside `LANG` because a host whose `/etc/profile` sets its own
    /// `LC_ALL` would otherwise ignore the `LANG` we sent — the pair is what the
    /// setting means, and sending only one is the half that silently does
    /// nothing there.
    var shellExportLines: [String] {
        let locales = localeEnvironment
        var lines = ["LANG", "LC_ALL"].compactMap { name in
            locales[name].map { "export \(name)=\($0)" }
        }
        if exportClientEnv { lines.append("export \(Self.variable)=1") }
        return lines
    }

    static let variable = "CQUTMUX_CLIENT"

    // MARK: - Locale rules

    /// `LANG` and `LC_ALL` for a locale, or empty when it is not one we should
    /// send. Both names get the same locale; see `shellExportLines` for why the
    /// pair and not just `LANG`.
    static func localeVariables(for locale: String) -> [String: String] {
        guard isExportableLocale(locale) else { return [:] }
        return ["LANG": locale, "LC_ALL": locale]
    }

    /// Whether a locale is one we can safely put into a session.
    ///
    /// Two tests, and both matter. It has to *be* a UTF-8 locale, because the
    /// point of setting it is a terminal that can render the agent's output; and
    /// it has to consist only of the characters a locale name is made of, since
    /// the value goes into an `export` line typed at a shell — a name carrying a
    /// newline or a `;` would not set a variable, it would run a command.
    static func isExportableLocale(_ locale: String) -> Bool {
        guard !locale.isEmpty, isUTF8(locale) else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._@-")
        return locale.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Whether a name is a UTF-8 locale, by the naming libc shares: the encoding
    /// is the last `.`-separated component, spelled `UTF-8` or `utf8`. So
    /// `en_US.UTF-8` and `C.utf8` are, and `C`, `POSIX` and `en_US.ISO-8859-1`
    /// are not.
    static func isUTF8(_ locale: String) -> Bool {
        // The modifier is `@euro` in `de_DE.UTF-8@euro`, and it comes *after*
        // the encoding — reading to the end of the name would see `UTF-8@euro`
        // and call a perfectly ordinary locale unusable.
        let named = locale.split(separator: "@", maxSplits: 1).first.map(String.init) ?? locale
        guard named.contains("."), let encoding = named.split(separator: ".").last else { return false }
        return encoding.lowercased().replacingOccurrences(of: "-", with: "") == "utf8"
    }
}
