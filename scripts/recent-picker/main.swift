import Foundation

// What the session picker's Recent tab offers.
//
// Three sources that look identical once drawn, and one distinction that
// disappears if it is wrong: a host asked not to look at its agent logs and a
// host that looked and found nothing both produce an empty list, and only one
// of them should say "discovery is off". The rule is Foundation-only, so it runs
// here without a simulator.

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

let last = LastSession(mux: "tmux", name: "work", window: "2")
let claude = RecentDirectoryBoard.Entry(path: "/srv/app", at: 1_700_000_000_000, agent: "claude", inferred: false)
let codex = RecentDirectoryBoard.Entry(path: "/srv/api", at: 1_700_000_001_000, agent: "codex", inferred: true)

func board(_ entries: [RecentDirectoryBoard.Entry], enabled: Bool = true) -> RecentDirectoryBoard {
    RecentDirectoryBoard(enabled: enabled, available: true, error: nil, directories: entries)
}

// MARK: - The order

// Everything present, in the order the tab draws: the session first (it is the
// one thing the app recorded about *where the user was*, not just where they
// looked), then visited folders, then the host's discovery.
check(RecentPicker.sections(last: last, visited: ["~/dev"], discovered: board([claude]))
        == [.lastSession(last), .visited(["~/dev"]), .agentFolders([claude])],
      "all three sources appear, in order")

// MARK: - Nothing to show

// No record anywhere and no discovery answer: the view shows its placeholder
// rather than an empty list, which is what this empty array means.
check(RecentPicker.sections(last: nil, visited: [], discovered: nil).isEmpty,
      "nothing recorded and no answer offers nothing")

// An answer that says "enabled, but no folders" is also nothing — an "Agent
// history" header over an empty list would promise a section that is not there,
// on every host whose agents have no usable logs.
check(RecentPicker.sections(last: nil, visited: [], discovered: board([])).isEmpty,
      "an enabled discovery with no folders adds no section")

// MARK: - The distinction that disappears when it is wrong

// Asked not to look. This is the case the whole type exists for: it must be a
// section, not an absence, because "we did not look" and "there is nothing"
// read the same as a bare empty list.
check(RecentPicker.sections(last: nil, visited: [], discovered: board([], enabled: false))
        == [.discoveryOff],
      "a host asked not to look says so rather than looking empty")

// A discovery error still means the host answered; the section is driven by
// whether discovery is on, not by whether it succeeded.
check(RecentPicker.sections(last: nil, visited: [], discovered: board([], enabled: false))
        .contains(.discoveryOff),
      "discovery-off is reported even when the board also carries an error")

// MARK: - Independence of the sources

// The app's own record is shown whether or not discovery is on: turning
// discovery off stops the *host* from being read, not the app from remembering.
check(RecentPicker.sections(last: last, visited: ["~/dev"], discovered: board([], enabled: false))
        == [.lastSession(last), .visited(["~/dev"]), .discoveryOff],
      "visited folders survive discovery being off")

// And vice versa: the host's folders appear with no visit recorded here.
check(RecentPicker.sections(last: nil, visited: [], discovered: board([claude, codex]))
        == [.agentFolders([claude, codex])],
      "agent folders appear with nothing recorded on the device")

// A last session with no visited folders and no discovery: only the session.
check(RecentPicker.sections(last: last, visited: [], discovered: nil) == [.lastSession(last)],
      "the last session alone is a section")

if failures > 0 {
    print("\nRECENT_PICKER_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nRECENT_PICKER_PASS  (\(checks) checks)")
