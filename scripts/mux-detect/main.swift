import Foundation

// Which multiplexer a host's session command starts.
//
// This exists because the obvious implementation is wrong in a way that ships
// today's own defaults into it: `contains("tmux")` also matches the session
// *name* in our default `zellij attach -c cqutmux`, so a zellij host would be
// handed a row of tmux prefix keystrokes. The row sends control bytes into
// whatever is in the pane, so that is not a cosmetic mistake.
//
// `Host` is Foundation-only, so this runs without a simulator.

var failures = 0
var checks = 0

func mux(_ command: String) -> String? {
    var host = Host()
    host.sessionCommand = command
    return host.mux
}

func check(_ command: String, _ expected: String?, _ label: String) {
    checks += 1
    let got = mux(command)
    if got == expected {
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label): \(command) → \(String(describing: got)), wanted \(String(describing: expected))")
    }
}

// The defaults, both of them.
check("tmux new -A -s cqutmux", "tmux", "our default tmux command is recognised")
check("zellij attach -c cqutmux", "zellij", "our default zellij command is zellij, not tmux")
check("herdr --session cqutmux", "herdr", "our default herdr command is herdr")

// The bug this file is written for, stated directly: a session *named* after
// the app must not be mistaken for the multiplexer.
check("zellij attach -c cqutmux", "zellij", "a session named cqutmux is not a tmux command")
check("herdr --session cqutmux", "herdr", "same for herdr")
check("zellij --session tmuxish", "zellij", "a zellij session whose name contains tmux is still zellij")

// Paths: tmux is often not on the default PATH, and people write the full path.
check("/usr/local/bin/tmux new -s work", "tmux", "an absolute path to tmux is recognised")
check("/opt/homebrew/bin/tmux", "tmux", "a path with no arguments is recognised")
check(".exe", nil, "a bare .exe is not a mux")

// Chained commands, which are how people actually set a working directory.
check("cd ~/code && tmux new -A -s work", "tmux", "a chained command is read past the `&&`")
check("cd x; zellij", "zellij", "a `;` separated command is read")
check("source ~/.zshrc | tmux", "tmux", "a pipe is read")

// Case.
check("TMUX new -s work", "tmux", "an upper-case command word is recognised")

// The honest answer when we do not know, which hides the row.
check("", nil, "no command means no mux")
check("bash -l", nil, "a plain shell is not a mux")
check("/usr/bin/env zsh", nil, "an unrecognised command is not guessed at")
check("exec $SHELL", nil, "a wrapper we cannot read is not guessed at")

if failures > 0 {
    print("\nMUXDETECT_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nMUXDETECT_PASS  (\(checks) checks)")
