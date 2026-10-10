import Foundation

// Whether the terminal resumes the last session, and what it resumes to.
//
// Both directions of a wrong answer are silent. Resuming when the screen is
// already on that session types an attach command into a live pane; resuming
// over the top of a deep link fights the link; failing to resume at all just
// opens the shell and looks like the feature was never there. `LastSession.swift`
// is Foundation-only, so the decision runs here without a simulator.

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

let tmux = LastSession(mux: "tmux", name: "work", window: "2")
let bare = LastSession(mux: "zellij", name: "dev", window: nil)

// MARK: - When to resume

// The ordinary case: a session was recorded and a fresh terminal is opening on
// the host, so it resumes — window and all.
check(SessionResume.action(hasLink: false, last: tmux, current: nil)
        == .restore(tmux, window: "2"),
      "a recorded session is restored, landing on its window")

// A session with no window recorded resumes to the session, not to a window it
// never knew about — a guessed window is a jump to the wrong place.
check(SessionResume.action(hasLink: false, last: bare, current: nil)
        == .restore(bare, window: nil),
      "a session with no window restores without a jump")

// Nothing recorded: the terminal opens on the shell, which is what an app with
// no history should do.
check(SessionResume.action(hasLink: false, last: nil, current: nil) == .none,
      "no recorded session resumes nothing")

// A link is the instruction about which session to be in. Resuming over it
// would fight the link, and the two arrive on the same signal.
check(SessionResume.action(hasLink: true, last: tmux, current: nil) == .none,
      "a deep link suppresses resuming rather than racing it")

// Already attached to the remembered session: typing an attach command again
// would land in the pane that is running whatever the user is doing.
check(SessionResume.action(hasLink: false, last: tmux, current: tmux) == .none,
      "already on the remembered session resumes nothing")

// Attached to a *different* session is exactly when resuming should still fire —
// this is the case that separates "already there" from "never touch what is on
// screen", and getting it backwards would make resume do nothing whenever
// anything was open.
check(SessionResume.action(hasLink: false, last: tmux, current: bare)
        == .restore(tmux, window: "2"),
      "a different current session still resumes the remembered one")

// MARK: - The store

// Round-trips through a private defaults domain, including the nil window —
// which is the encoding most likely to be dropped, since a missing key and an
// explicit nil look the same once written.
let suite = "cqutmux.check.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }

// Two hosts with different addresses: the store is keyed by hostname and port,
// so two hosts that share an address *are* one host — which is the behaviour
// under test, and a fixture using two bare `Host()`s would collide on ":22".
var host = Host()
host.hostname = "alpha.example"
var other = Host()
other.hostname = "beta.example"
other.port = 2222

let store = LastSessionStore(defaults: defaults)
check(store.last(for: host) == nil, "a fresh store remembers nothing")
store.record(tmux, for: host)
check(store.last(for: host) == tmux, "a recorded session reads back")
check(store.last(for: other) == nil, "and it is filed under its own host")

// The nil-window case, which is the one a naive encoder gets wrong.
store.record(bare, for: other)
check(store.last(for: other) == bare, "a session with no window reads back as no window")

// A second store over the same defaults sees what the first wrote: the whole
// point is that it survives the app closing.
let reopened = LastSessionStore(defaults: defaults)
check(reopened.last(for: host) == tmux, "the record survives a new store over the same defaults")

// Re-recording replaces rather than appends; there is only ever one per host.
store.record(bare, for: host)
check(store.last(for: host) == bare, "recording again replaces the remembered session")

// An empty name is refused: it would decode back as a session named "" and
// resume by attaching to nothing.
store.record(LastSession(mux: "tmux", name: "", window: nil), for: host)
check(store.last(for: host) == bare, "an empty session name is not recorded")

store.clear(for: host)
check(store.last(for: host) == nil, "clearing forgets the session")

if failures > 0 {
    print("\nLAST_SESSION_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nLAST_SESSION_PASS  (\(checks) checks)")