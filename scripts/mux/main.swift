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

// MARK: - The two prefixes are separate settings

// tmux and herdr are configured by different files, and a host commonly runs
// both. Sharing one stored prefix would make changing the tmux prefix silently
// rebind every herdr shortcut, which is the kind of bug that only shows up as
// "the gestures stopped working after I changed an unrelated setting".
settings.tmuxPrefix = .controlA
check(settings.herdrPrefix == .controlB,
      "changing the tmux prefix leaves herdr's alone")
settings.herdrPrefix = .controlSpace
check(MuxSettings(store: defaults).herdrPrefix == .controlSpace,
      "herdr's prefix survives a relaunch")
check(MuxSettings(store: defaults).tmuxPrefix == .controlA,
      "and reloading herdr's does not disturb tmux's")

// The prefix a host answers to, which is what every gesture reads.
check(settings.prefix(for: "herdr") == .controlSpace, "a herdr host gets herdr's prefix")
check(settings.prefix(for: "tmux") == .controlA, "a tmux host gets tmux's prefix")
check(settings.prefix(for: "zellij") == .controlA, "a zellij host falls through to tmux's")
check(settings.prefix(for: nil) == .controlA, "and so does a host we could not classify")

// MARK: - The multiplexer chords

// These are read from the programs' own published defaults, and getting one
// wrong is not a no-op the way a mistyped tmux key is — in herdr `pane` and
// `tab` are one letter from their neighbours, and the uppercase forms are
// separate bindings. So each byte is asserted against the letter the page
// lists, spelled out rather than derived from the table under test.
let tmuxPrefix = MuxSettings.Prefix.controlB
let herdrPrefix = MuxSettings.Prefix.controlB

func bytes(_ command: MuxSettings.MuxCommand, _ mux: String?,
           _ prefix: MuxSettings.Prefix = .controlB) -> [UInt8]? {
    command.bytes(prefix: prefix, mux: mux)
}

check(bytes(.nextPane, "tmux") == [0x02, 0x6F], "tmux: prefix then o moves to the next pane")
check(bytes(.previousPane, "tmux") == [0x02, 0x3B], "tmux: prefix then ; moves back")
check(bytes(.nextTab, "tmux") == [0x02, 0x6E], "tmux: prefix then n is the next window")
check(bytes(.previousTab, "tmux") == [0x02, 0x70], "tmux: prefix then p is the previous window")
check(bytes(.zoomPane, "tmux") == [0x02, 0x7A], "tmux: prefix then z zooms the pane")

check(bytes(.nextPane, "herdr") == [0x02, 0x6A], "herdr: prefix then j moves to the next pane")
check(bytes(.previousPane, "herdr") == [0x02, 0x6B], "herdr: prefix then k moves back")
check(bytes(.nextTab, "herdr") == [0x02, 0x6E], "herdr: prefix then n is the next tab")
check(bytes(.previousTab, "herdr") == [0x02, 0x70], "herdr: prefix then p is the previous tab")
check(bytes(.zoomPane, "herdr") == [0x02, 0x7A], "herdr: prefix then z zooms the pane")
check(bytes(.workspaceNavigator, "herdr") == [0x02, 0x77],
      "herdr: prefix then w opens the workspace navigator")
check(bytes(.gotoPrompt, "herdr") == [0x02, 0x67], "herdr: prefix then g opens the goto prompt")

// The prefix in front is the *user's*, not a constant baked into the table.
check(bytes(.zoomPane, "herdr", .controlA) == [0x01, 0x7A],
      "a rebound prefix is the one that goes on the wire")
check(bytes(.nextTab, "herdr", .controlSpace) == [0x00, 0x6E],
      "herdr's chords honour a rebound prefix too")

// Zellij has no prefix, so its commands are lines its own CLI runs. A control
// byte here would be typed into whatever the pane is running.
check(bytes(.nextTab, "zellij") == Array("zellij action go-to-tab 1\n".utf8),
      "zellij switches tab through its own CLI, not a prefix key")
check(bytes(.previousTab, "zellij") == Array("zellij action go-to-previous-tab\n".utf8),
      "zellij's previous tab is a CLI action")
check(bytes(.zoomPane, "zellij") == Array("zellij action toggle-fullscreen\n".utf8),
      "zellij's zoom is a CLI action")
for command in [MuxSettings.MuxCommand.nextTab, .previousTab, .zoomPane] {
    let sent = bytes(command, "zellij") ?? []
    check(!sent.contains(0x1B) && !sent.contains(0x02),
          "\(command.label) on zellij sends no control bytes")
}

// A command a mux cannot express must return nothing at all. Sending a tmux
// chord at a plain shell types a control character into whatever is running.
check(bytes(.nextPane, nil) == nil, "a host with no multiplexer sends nothing for a pane move")
check(bytes(.nextTab, nil) == nil, "and nothing for a tab move")
check(bytes(.zoomPane, nil) == nil, "and nothing for a zoom")
check(bytes(.workspaceNavigator, "tmux") == nil, "workspace navigation is herdr only")
check(bytes(.gotoPrompt, "tmux") == nil, "and so is the goto prompt")
check(bytes(.nextPane, "zellij") == nil,
      "zellij gets no pane move — its mode-entry key cannot be sent as one chord")
check(bytes(.previousPane, "zellij") == nil, "nor a backward one")

// Every command has a destination on at least one mux, or it is a case that can
// never fire and a picker entry that could never do anything.
for command in MuxSettings.MuxCommand.allCases {
    let reachable = ["tmux", "zellij", "herdr"].contains { command.bytes(prefix: .controlB, mux: $0) != nil }
    check(reachable, "\(command.label) is reachable on some multiplexer")
}

// MARK: - Which direction means what

// The sweeps consult this before a touch begins, so a direction that maps to
// nothing is what keeps two-finger scrolling working on a plain shell.
check(MuxSettings.MuxCommand.matching(horizontal: .next, vertical: nil, mux: "tmux") == .nextPane,
      "a sideways sweep forward moves to the next pane")
check(MuxSettings.MuxCommand.matching(horizontal: .previous, vertical: nil, mux: "tmux") == .previousPane,
      "and backwards to the previous one")
check(MuxSettings.MuxCommand.matching(horizontal: nil, vertical: .next, mux: "tmux") == .nextTab,
      "a vertical sweep forward moves to the next tab on tmux")
check(MuxSettings.MuxCommand.matching(horizontal: nil, vertical: .next, mux: "zellij") == .nextTab,
      "and on zellij")
check(MuxSettings.MuxCommand.matching(horizontal: nil, vertical: .next, mux: "herdr") == .workspaceNavigator,
      "herdr has no next-workspace key, so its vertical sweep opens the navigator")
check(MuxSettings.MuxCommand.matching(horizontal: nil, vertical: .previous, mux: "herdr") == .workspaceNavigator,
      "in both directions")
check(MuxSettings.MuxCommand.matching(horizontal: .next, vertical: nil, mux: nil) == nil,
      "a host with no multiplexer claims no direction at all")
check(MuxSettings.MuxCommand.matching(horizontal: .next, vertical: nil, mux: "zellij") == nil,
      "and zellij claims no sideways sweep, since its pane moves are unreachable")
check(MuxSettings.MuxCommand.matching(horizontal: nil, vertical: nil, mux: "tmux") == nil,
      "a sweep with no axis maps to nothing")

if failures > 0 {
    print("\nMUX_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nMUX_PASS  (\(checks) checks)")