import Foundation

// The Glass Effect setting.
//
// Two failures here are invisible on the device the setting was flipped on, and
// both are what these checks are for.
//
// The first is the default. `Bool` read through `bool(forKey:)` answers false
// for a key that was never set, so the obvious implementation of "on by
// default" ships as "off on every existing install" the first time the store is
// built — and a store is built at launch, before anyone has opened the screen.
// There is no crash and no log line; the app just stops looking like itself.
//
// The second is a value that does not survive a relaunch. It is
// indistinguishable, from the user's side, from a switch that never worked, and
// the fix (writing on `didSet`) is one line that nothing else would miss.
//
// Version gating is deliberately NOT checked here. This binary is built for
// macOS, where `#available(iOS 26.0, *)` takes its `*` branch and answers
// "yes" — the opposite of what a device on the deployment target gets. That
// check lives in the shell wrapper, on the source and the project spec.

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

/// A store on a suite of its own, cleared first, so this never edits the
/// settings of whoever ran it.
func store(_ name: String) -> ToolbarSettings {
    let suite = "cqutmux.toolbar.test.\(name)"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return ToolbarSettings(store: UserDefaults(suiteName: suite)!)
}

/// The same store as a fresh launch would build it: same suite, nothing
/// cleared. Wiping here would erase the very state these checks are about.
func relaunch(_ name: String) -> ToolbarSettings {
    ToolbarSettings(store: UserDefaults(suiteName: "cqutmux.toolbar.test.\(name)")!)
}

// MARK: - The default

let fresh = store("default")
check(fresh.glassEffect == true, "glass is on for an install that never chose")

// The failure this guards against is the default reading as `false`. Said in
// the negative as well, because "equals true" passes for an unrelated reason if
// the property is ever changed off `Bool`.
check(fresh.glassEffect != false, "the default is not the `bool(forKey:)` false")

// MARK: - Writing

let off = store("off")
off.glassEffect = false
check(off.glassEffect == false, "turning the glass off reads back as off")
check(relaunch("off").glassEffect == false,
      "off survives a relaunch — the value is written, not just held")

let on = store("on")
on.glassEffect = false
on.glassEffect = true
check(relaunch("on").glassEffect == true,
      "turning it back on survives a relaunch too")

// MARK: - The stored value

// Named in the source and read back by hand here: a rename that misses one of
// the two is a setting that silently stops persisting, which looks exactly like
// the app forgetting the choice.
let named = UserDefaults(suiteName: "cqutmux.toolbar.test.key")!
UserDefaults.standard.removePersistentDomain(forName: "cqutmux.toolbar.test.key")
ToolbarSettings(store: named).glassEffect = false
check(named.object(forKey: "cqutmux.toolbar.glassEffect") as? Bool == false,
      "the value lands under cqutmux.toolbar.glassEffect, namespaced like the rest")

// A key holding something other than a bool (an older build, a hand-edited
// plist) should read as the default rather than as off.
let wrongType = UserDefaults(suiteName: "cqutmux.toolbar.test.wrongType")!
UserDefaults.standard.removePersistentDomain(forName: "cqutmux.toolbar.test.wrongType")
wrongType.set("yes", forKey: "cqutmux.toolbar.glassEffect")
check(ToolbarSettings(store: wrongType).glassEffect == true,
      "a non-bool value falls back to the default, not to off")

// MARK: - What a pinch does

// The default has to be the font, and not out of sentiment: a pinch has been
// the font-size control since before this setting existed, and it is the only
// way to resize the terminal's text without leaving a session. A build that
// flipped the default would take that away from every existing install.
let pinchFresh = UserDefaults(suiteName: "cqutmux.toolbar.test.pinch-fresh")!
UserDefaults.standard.removePersistentDomain(forName: "cqutmux.toolbar.test.pinch-fresh")
check(ToolbarSettings(store: pinchFresh).pinchAction == .fontSize,
      "a fresh install pinches to resize the font")

let pinchSuite = UserDefaults(suiteName: "cqutmux.toolbar.test.pinch")!
UserDefaults.standard.removePersistentDomain(forName: "cqutmux.toolbar.test.pinch")
let pinch = ToolbarSettings(store: pinchSuite)
pinch.pinchAction = .zoomPane
check(ToolbarSettings(store: pinchSuite).pinchAction == .zoomPane,
      "choosing the pane zoom survives a relaunch")
check(pinchSuite.string(forKey: "cqutmux.toolbar.pinchAction") == "zoomPane",
      "and is stored by name, so a reordering of the cases cannot change it")

// A stored value from a build that had a different case is read as the default
// rather than as nothing — the terminal must still have a working pinch.
pinchSuite.set("magnify", forKey: "cqutmux.toolbar.pinchAction")
check(ToolbarSettings(store: pinchSuite).pinchAction == .fontSize,
      "an unknown stored action falls back to the font size, which is always valid")

// The two readings are distinct, and each one is a case a check can name. If a
// future edit ever collapsed them into one, the default that this whole
// divergence rests on would stop being expressible.
check(ToolbarSettings.PinchAction.allCases.count == 2,
      "a pinch has exactly two readings: the font, or the pane")
check(Set(ToolbarSettings.PinchAction.allCases.map(\.label)).count == 2,
      "and the two are distinguishable on the screen")
check(ToolbarSettings.PinchAction.zoomPane.detail.contains("multiplexer"),
      "the zoom reading says what it needs, so choosing it is informed")

print("")
if failures == 0 {
    print("toolbar: \(checks) checks passed")
} else {
    print("toolbar: \(failures) of \(checks) failed")
    exit(1)
}