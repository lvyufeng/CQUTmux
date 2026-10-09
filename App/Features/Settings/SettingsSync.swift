import Foundation
import Observation

/// Carries the parts of a configuration that are safe to move between devices.
///
/// Deliberately **not** the whole of each store. What is here is the set of
/// preferences whose worst case is mildly annoying — the wrong font, the wrong
/// theme — and what is absent is anything whose worst case is worse than that:
/// key material, gateway tokens, and the credential-sync toggle itself.
///
/// That last absence is the important one. Moshi syncs credentials as a
/// separate opt-in *on top of* settings sync, and a settings payload that
/// quietly carried an SSH key would turn "sync my theme" into "copy my private
/// key to every device on the account", which is not what the switch says. The
/// key lives in the Keychain and stays there.
struct SyncPayload: Codable, Equatable {
    /// Bumped when a field changes meaning, so an older build can decline a
    /// payload rather than misread it.
    var version: Int = 1

    var hosts: [Host] = []

    var themeName: String?
    var importedThemes: [TerminalTheme] = []

    var fontFamily: String?
    var fontSize: Double?
    var lineSpacing: Double?
    var cjkFallback: String?

    var cursorShape: String?
    var cursorBlinks: Bool?

    var sessionLayout: String?
    var speechEngine: String?

    /// When this device last wrote the payload. Used only to decide which side
    /// is newer when both have changed; the clock is the device's, so a badly
    /// wrong clock loses that comparison. That is acceptable here because the
    /// alternative — a Lamport clock threaded through every store — would cost
    /// far more than re-picking a font.
    var updatedAt: Date = .distantPast
}

/// Reads the current configuration into a payload and writes one back.
///
/// Split from the store so the merge rules can be checked without iCloud:
/// `scripts/settings-sync/run.sh` compiles this file with a fake key-value
/// store and exercises conflicts, which are the only part of sync that is
/// genuinely hard to get right and impossible to reproduce on demand.
@Observable
final class SettingsSync {
    enum Decision: Equatable {
        case identical
        case pushLocal
        case pullRemote
        /// Both sides changed since the last exchange. Merged rather than
        /// picked, because a conflict here is usually two devices editing
        /// different settings, and discarding either side loses real work.
        case merge
    }

    private let defaults: UserDefaults
    private static let lastKnownKey = "cqutmux.sync.lastKnown"

    /// The payload as this device last agreed with the cloud. The baseline for
    /// deciding which side moved, so "changed" means changed relative to the
    /// last sync rather than relative to defaults.
    private(set) var lastKnown: SyncPayload = SyncPayload()

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "cqutmux.sync.enabled")
            if !isEnabled { forget() }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: "cqutmux.sync.enabled")
        isEnabled = enabled
        // Only restore the baseline when sync is on. A snapshot left on disk by
        // a device that turned sync off (or that the user is about to re-enable
        // after months) is not evidence about the current cloud state, and
        // treating it as the reference point would silently discard whatever
        // the cloud has moved on to.
        if enabled, let data = defaults.data(forKey: Self.lastKnownKey),
           let stored = try? JSONDecoder().decode(SyncPayload.self, from: data) {
            lastKnown = stored
        }
    }

    /// Which direction a sync should go, given what the cloud currently holds.
    func decide(local: SyncPayload, remote: SyncPayload?) -> Decision {
        guard let remote else { return .pushLocal }
        if local == remote { return .identical }
        let localMoved = local != lastKnown
        let remoteMoved = remote != lastKnown
        switch (localMoved, remoteMoved) {
        case (false, true): return .pullRemote
        case (true, false): return .pushLocal
        // Unreachable: reaching here means local != remote, so local and remote
        // cannot both equal the baseline. Present because the switch is
        // exhaustive, and mapped to the harmless direction rather than a trap —
        // if it ever does fire, pushing this device's state loses nothing that
        // the pull would have kept.
        case (false, false): return .pushLocal
        case (true, true): return .merge
        }
    }

    /// Combines two payloads that both moved. Local wins per-field, because the
    /// user is looking at this device — except for the host list, which is
    /// unioned, and imported themes, which are appended.
    ///
    /// Losing a host to a conflict is much worse than carrying one that was
    /// deleted elsewhere: the first means a machine you can no longer reach,
    /// the second is a row you can delete again. Themes the same — a duplicate
    /// import is deduplicated by id, a lost theme is gone.
    func merge(local: SyncPayload, remote: SyncPayload) -> SyncPayload {
        var merged = local

        var byID = Dictionary(uniqueKeysWithValues: remote.hosts.map { ($0.id, $0) })
        for host in local.hosts { byID[host.id] = host }
        merged.hosts = byID.values.sorted { $0.id.uuidString < $1.id.uuidString }

        var themes = Dictionary(uniqueKeysWithValues: remote.importedThemes.map { ($0.id, $0) })
        for theme in local.importedThemes { themes[theme.id] = theme }
        merged.importedThemes = themes.values.sorted { $0.id < $1.id }

        merged.updatedAt = Date()
        return merged
    }

    /// Records the payload both sides now agree on. Called after a successful
    /// exchange, never before: a baseline written on a failed sync would make
    /// the next one think nothing had changed and skip the retry.
    func accept(_ payload: SyncPayload) {
        lastKnown = payload
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.lastKnownKey)
        }
    }

    /// Drops the baseline when sync is turned off, so turning it back on cannot
    /// mistake a long-abandoned snapshot for the current cloud state.
    private func forget() {
        lastKnown = SyncPayload()
        defaults.removeObject(forKey: Self.lastKnownKey)
    }
}