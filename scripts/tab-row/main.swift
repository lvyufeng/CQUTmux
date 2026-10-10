// The tab quick-access row's mapping, checked without a simulator.
//
// The row is twenty buttons on every multiplexer, but three genuinely different
// mechanisms underneath: tmux reads its prefix plus the digit (and its command
// prompt past nine), herdr reads its own prefix, and zellij — which has no
// prefix at all — reads Ctrl-T followed by the number as a tab-mode binding.
//
// This is the part worth checking hardest, because the failure is silent in the
// direction that matters: a row that typed a bare digit into whatever program is
// running looks exactly like a tab switch that did nothing, and only reading the
// bytes distinguishes them. `scripts/tab-row-check.sh` reads them off a live host
// with `cat -v`; this asserts the mapping itself.

import Foundation

var checks = 0
var failures = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if condition {
        print("PASS  \(message)")
    } else {
        print("FAIL  \(message)")
        failures += 1
    }
}

let prefix = MuxSettings.Prefix.controlB

func select(_ number: Int, _ mux: String?,
            _ at: MuxSettings.Prefix = .controlB) -> [UInt8]? {
    MuxSettings.MuxCommand.selectTab(number, mux: mux, prefix: at)
}

// MARK: - The range

check(MuxSettings.MuxCommand.selectableTabs == 1...20,
      "the row offers tabs 1 through 20, as the page lists")
check(select(0, "tmux") == nil, "tab 0 is out of range")
check(select(21, "tmux") == nil, "and so is tab 21")

// MARK: - tmux: bare digits, then the command prompt

check(select(1, "tmux") == [0x02, 0x31], "tmux tab 1 is the prefix then the digit")
check(select(9, "tmux") == [0x02, 0x39], "tmux tab 9 is the prefix then the digit")
// The nine case matters on its own: a fix for 10+ that routed everything through
// the prompt would still pass a check that only knew about ten.
check(select(10, "tmux") == [0x02] + Array(":select-window -t 10\n".utf8),
      "tmux tab 10 goes through the command prompt, the only route it has")
check(select(20, "tmux") == [0x02] + Array(":select-window -t 20\n".utf8),
      "and so does the last one")

// MARK: - herdr: its own prefix, then its tab command

check(select(3, "herdr") == [0x02, 0x33], "herdr tab 3 is its prefix then the digit")
check(select(12, "herdr") == Array("herdr tab focus 12\n".utf8),
      "herdr past nine uses its own tab command, not a chord the page warns about")
// The prefix is the user's, so a host with a rebound prefix must change the bytes
// — this is the whole reason the value is passed in rather than baked in.
check(select(3, "herdr", .controlA) == [0x01, 0x33],
      "herdr's tab row follows the configured prefix")

// MARK: - zellij: Ctrl-T, and never the line command

check(select(2, "zellij") == [0x14, 0x32], "zellij tab 2 is Ctrl-T then the digit")
check(select(7, "zellij") == [0x14, 0x37], "and so is tab 7")
check(select(15, "zellij") == [0x14, 0x31, 0x35],
      "zellij's higher tabs are still the control byte plus the digits as typed")
// The trap: every other zellij command here is a `zellij action` line, and it
// would be natural to reach for `go-to-tab`. That line needs a shell to run it,
// and the shell is not what has focus while zellij is on screen — so the tab row
// must not use it.
check(!(select(2, "zellij") ?? []).starts(with: Array("zellij action".utf8)),
      "the tab row does not use zellij's line command, which needs the shell")
// Ctrl-T is not a prefix, so a user who rebinds their tmux prefix must not
// accidentally change what a zellij tab button sends.
check(select(2, "zellij") == select(2, "zellij", .controlA),
      "zellij's row ignores the configured prefix, since zellij has none")

// MARK: - A host with no multiplexer

check(select(1, nil) == nil, "a plain shell has no tab row")
// Which is the same call the view uses to decide whether to draw the row at all,
// so a host that gets nil here must not get twenty buttons.
for mux in ["tmux", "herdr", "zellij"] {
    check(select(1, mux) != nil, "a \(mux) host gets the row")
}

if failures > 0 {
    print("\nTAB_ROW_MAPPING_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nTAB_ROW_MAPPING_PASS  (\(checks) checks)")