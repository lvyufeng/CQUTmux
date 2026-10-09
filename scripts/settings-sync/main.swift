import Foundation

// Checks the sync decision and merge rules. These are the only part of sync
// that is genuinely hard to get right, and the only part that cannot be
// reproduced on demand — a conflict needs two devices that both moved since
// the last exchange, which no manual test can arrange.
//
// `SettingsSync` has no CloudKit dependency precisely so this needs no
// simulator and no iCloud account.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)")
    }
}

func payload(
    hosts: [UUID] = [], themes: [String] = [], font: String? = "Menlo",
    updated: Date = Date(timeIntervalSince1970: 1_000)
) -> SyncPayload {
    var p = SyncPayload()
    p.hosts = hosts.map { id in
        var host = Host()
        host.id = id
        host.hostname = id.uuidString
        return host
    }
    p.importedThemes = themes.map { name in
        TerminalTheme(
            id: "imported-\(name)", name: name, dark: true,
            background: "000000", foreground: "ffffff", cursor: "ffffff",
            accent: TerminalTheme.defaultAccent, selection: nil,
            ansi: Array(repeating: "ffffff", count: 16))
    }
    p.fontFamily = font
    p.updatedAt = updated
    return p
}

/// A store with sync off, so the tests do not touch the real defaults.
func store(_ name: String) -> SettingsSync {
    let defaults = UserDefaults(suiteName: "cqutmux.sync.test.\(name)")!
    defaults.removePersistentDomain(forName: "cqutmux.sync.test.\(name)")
    return SettingsSync(defaults: defaults)
}

// MARK: - Nothing to compare

let first = store("first")
check(
    first.decide(local: payload(), remote: nil) == .pushLocal,
    "a first sync with an empty cloud pushes"
)
check(
    first.decide(local: payload(), remote: payload()) == .identical,
    "two identical payloads need no work"
)

// MARK: - One side moved

let oneSided = store("onesided")
let baseline = payload(font: "Menlo")
oneSided.accept(baseline)

check(
    oneSided.decide(local: baseline, remote: payload(font: "Menlo")) == .identical,
    "open and closed with no edits is a no-op"
)
check(
    oneSided.decide(local: payload(font: "Courier"), remote: baseline) == .pushLocal,
    "only this device moved, so it pushes"
)
check(
    oneSided.decide(local: baseline, remote: payload(font: "Courier")) == .pullRemote,
    "only the far device moved, so it pulls"
)

// MARK: - Both sides moved

let both = store("both")
both.accept(baseline)
let localEdit = payload(font: "Courier")
let remoteEdit = payload(font: "Monaco")
check(
    both.decide(local: localEdit, remote: remoteEdit) == .merge,
    "both devices edited, so the result is a merge"
)

// A stale baseline — a snapshot that matches neither side, as after a
// half-finished sync — must not be read as "the other side moved" and pull over
// this device's work. It is read as "both moved", which merges, which is the
// safe reading: merging keeps both sides, and the alternative silently drops
// one of them.
let stale = store("stale")
stale.accept(payload(hosts: [UUID()], font: "Ghost"))
check(
    stale.decide(local: payload(font: "A"), remote: payload(font: "B")) == .merge,
    "a baseline matching neither side merges rather than discarding either"
)

// MARK: - Merge: hosts are unioned, not picked

let mergeLocal = payload(hosts: [UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!])
let mergeRemote = payload(hosts: [UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!])
let unioned = both.merge(local: mergeLocal, remote: mergeRemote)
check(unioned.hosts.count == 2, "a conflict keeps hosts from both sides")
check(
    Set(unioned.hosts.map(\.id)) == Set(mergeLocal.hosts.map(\.id) + mergeRemote.hosts.map(\.id)),
    "and they are exactly the two that went in"
)

// Same host on both sides: the local edit must win, since the user is here.
var localHost = Host()
localHost.id = mergeLocal.hosts[0].id
localHost.name = "edited here"
var remoteHost = localHost
remoteHost.name = "edited there"
var sameHosts = payload()
sameHosts.hosts = [localHost]
var remoteSame = payload()
remoteSame.hosts = [remoteHost]
let resolved = both.merge(local: sameHosts, remote: remoteSame)
check(resolved.hosts.count == 1, "one host edited on both sides stays one host")
check(resolved.hosts[0].name == "edited here", "and the local edit wins")

// A host deleted on one side and untouched on the other comes back. That is
// the deliberate direction: reachability matters more than tidiness, and the
// row can be deleted again.
let withBoth = payload(hosts: [UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!,
                               UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!])
let deletedOne = payload(hosts: [UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!])
let resurrected = both.merge(local: deletedOne, remote: withBoth)
check(resurrected.hosts.count == 2, "a host deleted on one side is restored by the merge")
check(
    resurrected.hosts.map(\.id).contains(UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!),
    "specifically the one the other side still had"
)

// MARK: - Merge: themes are unioned

let themes = both.merge(local: payload(themes: ["alpha"]), remote: payload(themes: ["beta"]))
check(themes.importedThemes.count == 2, "a conflict keeps themes from both sides")
check(
    Set(themes.importedThemes.map(\.name)) == ["alpha", "beta"],
    "and they are exactly the two that went in"
)
let sameTheme = both.merge(local: payload(themes: ["alpha"]), remote: payload(themes: ["alpha"]))
check(sameTheme.importedThemes.count == 1, "the same theme on both sides does not duplicate")

// MARK: - Merge: scalars prefer local

let scalars = both.merge(local: payload(font: "Courier"), remote: payload(font: "Monaco"))
check(scalars.fontFamily == "Courier", "a scalar conflict resolves to this device's value")

// The merged payload must itself be accepted as the new baseline, or the next
// sync sees the same conflict and merges forever.
both.accept(scalars)
check(
    both.decide(local: scalars, remote: scalars) == .identical,
    "the merged result becomes the baseline, so the conflict does not repeat"
)

// MARK: - Merge must not carry secrets

// The whole safety claim of settings sync is that it cannot move key material.
// If a field were ever added to the payload that held one, this is the check
// that should have been watching.
let encoded = try! JSONEncoder().encode(payload())
let json = String(data: encoded, encoding: .utf8)!
for forbidden in ["keySeed", "privateKey", "gatewayToken", "password", "token"] {
    check(
        !json.lowercased().contains(forbidden.lowercased()),
        "the payload never carries \(forbidden)"
    )
}

// A host serialises without its secrets — that is what makes the host list
// safe to sync at all.
var host = Host()
host.username = "alice"
host.authMethod = .key
let hostJSON = String(data: try! JSONEncoder().encode(host), encoding: .utf8)!
check(!hostJSON.contains("PRIVATE"), "a serialised host carries no private key")
check(
    hostJSON.contains("authMethod") && !hostJSON.lowercased().contains("passphrase"),
    "it records that a key is used, not the key"
)

// MARK: - The client marker travels, and only as a yes/no

// `exportClientEnv` is the newest field, and the one whose absence would be
// easiest to miss: without these, a payload written by an older build would
// silently keep resetting it. Its value is a `Bool?`, so the only thing that
// can reach the wire is `true`, `false` or nothing — no variable name, no
// value, and nothing that could be pointed at a secret.
var withMarker = SyncPayload()
withMarker.exportClientEnv = true
let markerJSON = String(data: try! JSONEncoder().encode(withMarker), encoding: .utf8)!
check(markerJSON.contains("exportClientEnv"), "the payload carries the client-marker setting")

var absent = SyncPayload()
check(
    String(data: try! JSONEncoder().encode(absent), encoding: .utf8)!
        .contains("exportClientEnv") == false,
    "an unset marker is omitted rather than sent as false"
)

// MARK: - The input settings travel, and an absent field is not "off"

// Same trap as the marker, in a worse form: these are three different shapes —
// two flags and a list — and each one has a *meaningful* default. A device that
// never touched its bar must not be told it removed every button, and a device
// with Meta off must not be told it is on.
var withInput = SyncPayload()
withInput.optionIsMeta = true
withInput.hideBarWithHardwareKeyboard = false
withInput.barItems = ["control", "dpad"]
withInput.dpadCorners = ["topLeading": "interrupt"]
withInput.hidesWindowRow = true
let inputJSON = String(data: try! JSONEncoder().encode(withInput), encoding: .utf8)!
check(inputJSON.contains("optionIsMeta"), "the payload carries Option-as-Meta")
check(inputJSON.contains("barItems"), "the payload carries the bar's item order")
check(inputJSON.contains("dpadCorners"), "the payload carries the corner bindings")
check(inputJSON.contains("hidesWindowRow"), "the payload carries the window row's visibility")

// The mux prefixes travel separately, for the same reason they are stored
// separately: one device whose tmux and herdr prefixes disagree would otherwise
// rebind one program's shortcuts on the other device from a single field.
var withMux = SyncPayload()
withMux.tmuxPrefix = "controlA"
withMux.herdrPrefix = "controlSpace"
withMux.muxGestures = false
let muxJSON = String(data: try! JSONEncoder().encode(withMux), encoding: .utf8)!
check(muxJSON.contains("herdrPrefix"), "the payload carries herdr's own prefix")
check(muxJSON.contains("muxGestures"), "the payload carries the mux-gesture switch")

var withPinch = SyncPayload()
withPinch.pinchZoomsPane = true
let pinchJSON = String(data: try! JSONEncoder().encode(withPinch), encoding: .utf8)!
check(pinchJSON.contains("pinchZoomsPane"), "the payload carries what a pinch does")

// A payload from before these fields existed must not be read as "this device
// turned the gestures off" — the omission has to mean "unchanged", which is the
// same trap the bar's item list has. Checked below, once `untouched` exists.

var untouched = SyncPayload()
let untouchedJSON = String(data: try! JSONEncoder().encode(untouched), encoding: .utf8)!
check(!untouchedJSON.contains("optionIsMeta"),
      "an untouched Option setting is omitted, not sent as false")
check(!untouchedJSON.contains("barItems"),
      "an unmodified bar is omitted, so it cannot be read as an empty one")
check(!untouchedJSON.contains("muxGestures"),
      "an untouched gesture switch is omitted, so it cannot be read as off")
check(!untouchedJSON.contains("pinchZoomsPane"),
      "and so is an untouched pinch preference")

// The reason the omission matters: `nil` is not `[]` on the wire, so a payload
// written before this field existed cannot be read as "this device removed
// every button" — which, if it could, would import a bar with nothing on it
// over a working one.
var emptied = SyncPayload()
emptied.barItems = []
check(
    String(data: try! JSONEncoder().encode(emptied), encoding: .utf8)!.contains("\"barItems\":[]"),
    "an explicit empty list encodes differently from an omitted one"
)

// MARK: - Enable/disable

let toggling = store("toggling")
toggling.accept(payload(font: "Before"))
toggling.isEnabled = false
check(toggling.lastKnown == SyncPayload(), "disabling sync drops the baseline")
toggling.isEnabled = true
// The distinction that matters: with the baseline gone, the remote's change is
// measured against nothing rather than against the snapshot from before sync
// was off — so the device neither treats an old cloud state as current nor
// reports a conflict that is really just staleness.
check(
    toggling.decide(local: payload(font: "After"), remote: payload(font: "Other")) == .merge,
    "re-enabling does not compare against a snapshot from before it was off"
)

// A baseline left on disk while sync is off must not be restored on relaunch,
// or the setting would keep a stale reference point alive across restarts.
let defaults = UserDefaults(suiteName: "cqutmux.sync.test.relaunch")!
defaults.removePersistentDomain(forName: "cqutmux.sync.test.relaunch")
let before = SettingsSync(defaults: defaults)
before.isEnabled = true
before.accept(payload(font: "Saved"))
before.isEnabled = false
let after = SettingsSync(defaults: defaults)
check(after.lastKnown == SyncPayload(), "a relaunch with sync off does not resurrect the baseline")

print("")
if failures == 0 {
    print("SETTINGS_SYNC_PASS  (\(checks) checks)")
} else {
    print("SETTINGS_SYNC_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}