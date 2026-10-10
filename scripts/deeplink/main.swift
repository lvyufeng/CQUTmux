import Foundation

// What a `cqutmux://` link parses to, checked without a simulator.
//
// `DeepLink.swift` is Foundation-only, and the parsing is the half of the
// feature a notification actually depends on: the value is pasted into a
// terminal or a webhook, so a link that parses to the wrong pane, or that
// silently drops the pane, is a tap that lands somewhere other than the
// notification was about — with nothing logged to say so.
//
// The cases below are grouped by the asymmetry the parser carries: tmux and
// zellij address a window (and tmux a pane) by number and a typo must be
// caught before it is typed at the shell, while herdr addresses its tab and
// pane by opaque ids and a number check there would reject every valid link.

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

/// The target a link parses to, or nil if it failed to parse.
func target(_ string: String) -> DeepLink.Target? {
    guard let url = URL(string: string) else { return nil }
    guard case .success(let link) = DeepLink.parse(url) else { return nil }
    return link.target
}

/// The parse error for a link, or nil if it parsed.
func error(_ string: String) -> DeepLink.ParseError? {
    guard let url = URL(string: string) else { return nil }
    guard case .failure(let err) = DeepLink.parse(url) else { return nil }
    return err
}

func isBadPane(_ err: DeepLink.ParseError?) -> Bool {
    if case .badPane = err { return true }
    return false
}

func isBadWindow(_ err: DeepLink.ParseError?) -> Bool {
    if case .badWindow = err { return true }
    return false
}

// MARK: - tmux: window and pane are numbers

// The link that existed before panes, unchanged: a window and no pane.
check(target("cqutmux://tmux?session=work&window=3")
        == .session(mux: "tmux", name: "work", window: "3", pane: nil),
      "a tmux link with only a window still parses as before")

// The new pane parameter on its own.
check(target("cqutmux://tmux?session=work&pane=2")
        == .session(mux: "tmux", name: "work", window: nil, pane: "2"),
      "a tmux link can name a pane without a window")

// Both together: the window is where the pane index counts, so a link that
// names both has to carry both.
check(target("cqutmux://tmux?session=work&window=1&pane=2")
        == .session(mux: "tmux", name: "work", window: "1", pane: "2"),
      "a tmux link carries a window and a pane together")

// A bad pane is caught at the parse, exactly as a bad window is — the reason
// the number is validated at all is so it is never typed at the shell.
check(isBadPane(error("cqutmux://tmux?session=work&pane=x")),
      "a non-numeric tmux pane is refused")
check(isBadWindow(error("cqutmux://tmux?session=work&window=x")),
      "a non-numeric tmux window is still refused")

// An empty value is as good as absent: the parser treats `pane=` as no pane,
// so the link attaches rather than failing on a stray ampersand.
check(target("cqutmux://tmux?session=work&pane=")
        == .session(mux: "tmux", name: "work", window: nil, pane: nil),
      "an empty tmux pane is treated as absent")

// MARK: - herdr: the tab and the pane are opaque ids, the alias is read

// `tab` is herdr's spelling and rides in the `window` slot the rest of the app
// already jumps with, so no second jump mechanism is needed.
check(target("cqutmux://herdr?workspace=w1&tab=w1:t2")
        == .session(mux: "herdr", name: "w1", window: "w1:t2", pane: nil),
      "a herdr link reads its tab into the window slot")

// The id is opaque, so it must not be number-checked: this is the asymmetry.
check(target("cqutmux://herdr?workspace=w1&tab=main") != nil,
      "a non-numeric herdr tab id is accepted")

// The older `window=` spelling on a herdr link still works, so a link written
// before `tab` existed does not stop working.
check(target("cqutmux://herdr?workspace=w1&window=w1:t5")
        == .session(mux: "herdr", name: "w1", window: "w1:t5", pane: nil),
      "a herdr link spelled with window still parses")

// `tab` is not read for tmux: a stray one does not become a window there.
check(target("cqutmux://tmux?session=work&tab=w1:t2")
        == .session(mux: "tmux", name: "work", window: nil, pane: nil),
      "tab is ignored on a tmux link")

// herdr's pane is an opaque `pane_id` from its snapshot, the same kind of value
// as its tab — so it rides in the `pane` slot the terminal already jumps with,
// rather than being dropped. The value is checked nowhere, because a number
// check here would reject every valid id the mux hands out.
check(target("cqutmux://herdr?workspace=w1&pane=w1:abc")
        == .session(mux: "herdr", name: "w1", window: nil, pane: "w1:abc"),
      "a herdr link reads its pane into the pane slot")
check(target("cqutmux://herdr?workspace=w1&tab=w1:t2&pane=bolt")
        == .session(mux: "herdr", name: "w1", window: "w1:t2", pane: "bolt"),
      "a herdr link carries its tab and opaque pane together")

// A blank value is still absent, so `pane=` on a herdr link attaches rather
// than carrying an empty id.
check(target("cqutmux://herdr?workspace=w1&pane=")
        == .session(mux: "herdr", name: "w1", window: nil, pane: nil),
      "an empty herdr pane is treated as absent")

// MARK: - zellij: behaviour unchanged, it addresses neither

check(target("cqutmux://zellij?session=dev&window=2")
        == .session(mux: "zellij", name: "dev", window: "2", pane: nil),
      "a zellij link still parses its window")
check(target("cqutmux://zellij?session=dev&pane=3")
        == .session(mux: "zellij", name: "dev", window: nil, pane: nil),
      "pane is ignored on a zellij link")

// MARK: - the session accessor carries the pane through

// The accessor is what the terminal reads; a pane that parses but is dropped
// here would be a link that opens the right session on the wrong pane.
if let url = URL(string: "cqutmux://tmux?session=work&window=1&pane=2"),
   case .success(let link) = DeepLink.parse(url),
   let session = link.session {
    check(session.mux == "tmux" && session.name == "work"
            && session.window == "1" && session.pane == "2",
          "the session accessor surfaces the pane to the caller")
} else {
    check(false, "the session accessor surfaces the pane to the caller")
}

// The same accessor is what carries an opaque herdr pane, so it is checked
// there too: a pane that reaches the target but not the accessor is still a
// link that opens the wrong pane.
if let url = URL(string: "cqutmux://herdr?workspace=w1&tab=w1:t2&pane=w1:abc"),
   case .success(let link) = DeepLink.parse(url),
   let session = link.session {
    check(session.mux == "herdr" && session.name == "w1"
            && session.window == "w1:t2" && session.pane == "w1:abc",
          "the session accessor surfaces an opaque herdr pane")
} else {
    check(false, "the session accessor surfaces an opaque herdr pane")
}

if failures > 0 {
    print("\n\(failures) of \(checks) checks failed")
    exit(1)
}
print("\nall \(checks) checks passed")