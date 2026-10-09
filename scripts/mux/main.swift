import Foundation

// The tmux prefix, and the byte it is.
//
// A wrong prefix is the quietest failure in the app: Jump-To sends the key,
// tmux ignores it, and the digit that was meant to select a window lands in
// whatever is running in the current pane. In a session with an agent at the
// prompt that means the agent receives a stray character. Nothing logs, nothing
// errors, and the only symptom is "the jump didn't work, and something odd got
// typed".
//
// So the arithmetic that turns a named prefix into the byte is worth checking
// on its own: a control key is `key & 0x1F`, and an off-by-one there is
// invisible until it is in front of a real tmux.

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

// MARK: - The bytes

// The three cases the picker offers, against the values a terminal actually
// sends. Ctrl-B is not "b with a flag" on the wire — it is 0x02.
check(MuxSettings.Prefix.controlB.byte == 0x02, "Ctrl-B is 0x02")
check(MuxSettings.Prefix.controlA.byte == 0x01, "Ctrl-A is 0x01")
check(MuxSettings.Prefix.controlSpace.byte == 0x00, "Ctrl-Space is NUL (0x00)")
check(MuxSettings.Prefix.controlB.bytes == [0x02], "a prefix sends exactly one byte")

// The rule the values come from, stated independently so a typo in the table
// above cannot also be a typo in this check.
for prefix in MuxSettings.Prefix.allCases {
    let key: UInt8
    switch prefix {
    case .controlB: key = UInt8(ascii: "b")
    case .controlA: key = UInt8(ascii: "a")
    case .controlSpace: key = 0x20
    }
    check(prefix.byte == key & 0x1F, "\(prefix.label) is its key masked to a control code")
}

// MARK: - Nothing else is a control key by accident

// The prefixes must be distinct, or two picker entries would send the same
// bytes and one of them would be a lie.
let allBytes = MuxSettings.Prefix.allCases.map(\.byte)
check(Set(allBytes).count == allBytes.count, "the prefixes are distinguishable on the wire")

let allSpellings = MuxSettings.Prefix.allCases.map(\.configSpelling)
check(Set(allSpellings).count == allSpellings.count, "no two prefixes show the same tmux spelling")

// The spelling is what the screen tells the user to look for in their tmux.conf,
// so it has to be the form tmux accepts, not a label invented here.
check(MuxSettings.Prefix.controlB.configSpelling == "C-b", "Ctrl-B is written C-b in tmux.conf")
check(MuxSettings.Prefix.controlSpace.configSpelling == "C-Space",
      "Ctrl-Space is written C-Space, which tmux parses")

for prefix in MuxSettings.Prefix.allCases {
    check(!prefix.label.isEmpty, "\(prefix.rawValue) has a label to show in the picker")
}

// MARK: - Reading back a stored value

// Forward compatibility: an unknown raw value (a prefix a newer build added, or
// a corrupted default) must land on the default rather than on nil or a crash.
check(MuxSettings.Prefix.named(nil) == .controlB, "a missing prefix defaults to Ctrl-B")
check(MuxSettings.Prefix.named("controlA") == .controlA, "a stored prefix is read back")
check(MuxSettings.Prefix.named("controlZ") == .controlB,
      "an unrecognised prefix falls back to Ctrl-B rather than failing")

// MARK: - It survives a relaunch, and does not touch a shared store

let suite = "cqutmux.mux-check"
UserDefaults.standard.removePersistentDomain(forName: suite)
let defaults = UserDefaults(suiteName: suite)!

let settings = MuxSettings(store: defaults)
check(settings.tmuxPrefix == .controlB, "a fresh install starts on tmux's own default")

settings.tmuxPrefix = .controlA
check(MuxSettings(store: defaults).tmuxPrefix == .controlA,
      "a changed prefix survives a relaunch")

settings.tmuxPrefix = .controlSpace
check(MuxSettings(store: defaults).tmuxPrefix == .controlSpace,
      "the last of the three round-trips too")

if failures > 0 {
    print("\nMUX_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nMUX_PASS  (\(checks) checks)")