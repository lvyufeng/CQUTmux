import Foundation
import Observation

/// Settings → Multiplexer: how this client talks to the mux on the host.
///
/// Only tmux needs a setting here. Jump-To and the session picker jump by
/// *sending the prefix key* rather than by typing a command, so the command is
/// interpreted by tmux and not typed into a pane an agent may be busy in. That
/// makes the prefix part of our wire format: the bytes have to be the ones the
/// user's `~/.tmux.conf` actually binds, and Ctrl-b is only the default.
///
/// Getting this wrong is silent. A user with `set -g prefix C-a` taps a window
/// in Jump-To, we send Ctrl-b and a digit, tmux does nothing with it, and the
/// digit lands in whatever is running in the pane. There is no error anywhere.
@Observable
final class MuxSettings {
    private enum Key {
        static let tmuxPrefix = "cqutmux.mux.tmuxPrefix"
        static let herdrPrefix = "cqutmux.mux.herdrPrefix"
    }

    /// Where the setting lives. Injectable so a check can use its own suite
    /// rather than editing the settings of whoever runs it.
    private let store: UserDefaults

    /// The prefixes worth offering.
    ///
    /// Deliberately a short list rather than a free-form key capture: the three
    /// here are the ones that appear in real `tmux.conf` files (`C-b` is the
    /// default, `C-a` the common GNU-screen muscle memory, `C-Space` the other
    /// one). Anything more exotic is a key we could not label, and a picker
    /// whose entries the user cannot recognize is worse than editing the file.
    enum Prefix: String, CaseIterable, Identifiable {
        case controlB, controlA, controlSpace

        var id: String { rawValue }

        var label: String {
            switch self {
            case .controlB: "Ctrl-B"
            case .controlA: "Ctrl-A"
            case .controlSpace: "Ctrl-Space"
            }
        }

        /// The `set -g prefix` spelling, which is what a `tmux.conf` says — so
        /// the screen can show the line to look for instead of asking the user
        /// to translate a byte.
        var configSpelling: String {
            switch self {
            case .controlB: "C-b"
            case .controlA: "C-a"
            case .controlSpace: "C-Space"
            }
        }

        /// The single byte the prefix is. A control key is `key & 0x1F`, which
        /// is why these are these numbers: b is 0x62, a is 0x61, space is 0x20.
        var byte: UInt8 {
            switch self {
            case .controlB: 0x02
            case .controlA: 0x01
            case .controlSpace: 0x00
            }
        }

        var bytes: [UInt8] { [byte] }

        static func named(_ raw: String?) -> Prefix {
            raw.flatMap(Prefix.init(rawValue:)) ?? .controlB
        }
    }

    var tmuxPrefix: Prefix {
        didSet { store.set(tmuxPrefix.rawValue, forKey: Key.tmuxPrefix) }
    }

    /// Herdr's prefix, kept separate from tmux's because the two programs are
    /// configured separately and a host can run both at once. Herdr defaults to
    /// Ctrl-B as well, but a user who has rebound one of them has almost
    /// certainly rebound only that one — sharing a single setting would break
    /// whichever of the two they did not mean to change.
    var herdrPrefix: Prefix {
        didSet { store.set(herdrPrefix.rawValue, forKey: Key.herdrPrefix) }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        tmuxPrefix = Prefix.named(store.string(forKey: Key.tmuxPrefix))
        herdrPrefix = Prefix.named(store.string(forKey: Key.herdrPrefix))
    }

    /// The prefix a host's multiplexer answers to.
    ///
    /// `mux` is `Host.mux`'s already-detected kind, and an unrecognised or nil
    /// one gets the tmux prefix: a host we could not classify is a host we have
    /// nothing better than the default for.
    func prefix(for mux: String?) -> Prefix {
        mux == "herdr" ? herdrPrefix : tmuxPrefix
    }

    /// A control sequence a multiplexer reads as one of its own key bindings.
    ///
    /// These are the keystrokes the header gestures, the pinch, and Herdr's
    /// shortcut panel send. They are *not* in `ShortcutGrammar`: that grammar
    /// produces at most one control byte followed by text, and the Herdr chords
    /// that end in a Shift-modified key (`prefix + X` for "kill pane") have no
    /// control form at all — X is 0x58 and `stop & 0x1F` would send Ctrl-X, which
    /// is a different binding. Sending the wrong one of those is a destructive
    /// mistranslation, so they live in a table that can be checked against
    /// published defaults rather than in a grammar that would have to guess.
    enum MuxCommand: String, CaseIterable, Codable {
        /// Move the focus to the next pane.
        case nextPane, previousPane
        /// Move the focus to the next tab/window.
        case nextTab, previousTab
        /// Toggle the focused pane between split and full-screen.
        case zoomPane
        /// Open the workspace navigator.
        case workspaceNavigator
        /// Open Herdr's goto prompt, which is how a tab past the ninth digit is
        /// reached.
        case gotoPrompt

        var label: String {
            switch self {
            case .nextPane: "Next pane"
            case .previousPane: "Previous pane"
            case .nextTab: "Next tab"
            case .previousTab: "Previous tab"
            case .zoomPane: "Zoom pane"
            case .workspaceNavigator: "Workspaces"
            case .gotoPrompt: "Goto"
            }
        }

        /// Whether this mux can express the command at all.
        ///
        /// Zellij is the awkward one. It has no prefix, so every command goes
        /// through `zellij action` — and for tabs and zoom that is fine, because
        /// those are line commands the shell runs. Moving the *focus* is not: the
        /// only action for it is `MoveFocus`, which is bound inside zellij's pane
        /// mode, and the mode-entry key (`Ctrl-p`) is only bound from the normal
        /// mode, so the chord cannot be sent as one blob from the terminal. A
        /// `MoveFocus` typed while still in pane mode would also leave the user
        /// typing `h` and `j` into zellij's mode instead of the shell. So the pane
        /// gestures are offered on tmux and herdr only, and a zellij host gets the
        /// tab row for what it does have.
        func isAvailable(on mux: String?) -> Bool {
            switch self {
            case .nextPane, .previousPane:
                return mux == "tmux" || mux == "herdr"
            case .nextTab, .previousTab, .zoomPane:
                return mux != nil
            case .workspaceNavigator, .gotoPrompt:
                return mux == "herdr"
            }
        }

        /// The bytes to send, or nil when this multiplexer has no such binding.
        ///
        /// Herdr's chords are read from its own documented defaults rather than
        /// guessed at, because the cost of guessing is asymmetric: a wrong key in
        /// tmux does nothing, but a wrong key in herdr is a *different binding* —
        /// `pane` and `tab` are one letter apart from their neighbours, and the
        /// uppercase forms are separate bindings entirely. Every byte below is the
        /// lowercase letter the page lists, with the prefix from the setting in
        /// front of it.
        ///
        /// Zellij gets a `zellij action` line instead, because it has no prefix to
        /// send at all.
        func bytes(prefix: MuxSettings.Prefix, mux: String?) -> [UInt8]? {
            guard isAvailable(on: mux) else { return nil }
            let head = prefix.bytes
            switch (mux, self) {
            case ("tmux", .nextPane): return head + [0x6F]        // prefix o
            case ("tmux", .previousPane): return head + [0x3B]    // prefix ;
            case ("tmux", .nextTab): return head + [0x6E]         // prefix n
            case ("tmux", .previousTab): return head + [0x70]     // prefix p
            case ("tmux", .zoomPane): return head + [0x7A]        // prefix z
            case ("zellij", .nextTab): return Array("zellij action go-to-tab 1\n".utf8)
            case ("zellij", .previousTab):
                // `go-to-tab` takes an index, not a direction, so "previous" is a
                // command the host's own zellij resolves against the current tab.
                return Array("zellij action go-to-previous-tab\n".utf8)
            case ("zellij", .zoomPane): return Array("zellij action toggle-fullscreen\n".utf8)
            case ("herdr", .nextPane): return head + [0x6A]       // prefix j
            case ("herdr", .previousPane): return head + [0x6B]   // prefix k
            case ("herdr", .nextTab): return head + [0x6E]        // prefix n
            case ("herdr", .previousTab): return head + [0x70]    // prefix p
            case ("herdr", .zoomPane): return head + [0x7A]       // prefix z
            case ("herdr", .workspaceNavigator): return head + [0x77]  // prefix w
            case ("herdr", .gotoPrompt): return head + [0x67]     // prefix g
            default:
                return nil
            }
        }

        /// The highest tab number the quick-access row offers.
        ///
        /// The page lists "Tab 1–20" for tmux, herdr and zellij alike, so the row
        /// is the same twenty buttons everywhere and only what each button *sends*
        /// differs. That is the point of putting the number here rather than in
        /// the view: the row cannot drift into offering a number one multiplexer
        /// cannot reach.
        static let selectableTabs = 1...20

        /// What tapping tab `number` sends, or nil when this multiplexer has no
        /// way to jump to a number.
        ///
        /// These are three genuinely different mechanisms, and the page
        /// distinguishes them:
        ///
        /// * tmux reads `prefix` + the digit itself, so bare digits work and the
        ///   row can reach all twenty without a prompt.
        /// * zellij has no prefix at all. `Ctrl-T` is its *tab mode* key, and the
        ///   number is read from inside that mode — which is why this is the one
        ///   row entry that sends a control byte rather than a `zellij action`
        ///   line. Typing the line command (`go-to-tab N`) would need the shell,
        ///   and the shell is not what has focus while a TUI is on screen.
        /// * herdr has tabs of its own — see `gotoPrompt`, which is how a tab past
        ///   the ninth is reached.
        static func selectTab(_ number: Int, mux: String?, prefix: Prefix) -> [UInt8]? {
            guard selectableTabs.contains(number) else { return nil }
            switch mux {
            case "tmux":
                if number <= 9 { return prefix.bytes + Array(String(number).utf8) }
                // tmux binds the bare digits to its first nine windows. A tenth
                // has no bare binding, so it goes through the command prompt —
                // which is what the row did before it offered more than nine.
                return prefix.bytes + Array(":select-window -t \(number)\n".utf8)
            case "zellij":
                // Ctrl-T is 0x14, zellij's tab-mode key; the number is read from
                // inside that mode. This is the one row entry that sends a control
                // byte rather than a `zellij action` line: the line form needs the
                // shell to run it, and the shell is not what has focus while a TUI
                // is on screen.
                return [0x14] + Array(String(number).utf8)
            case "herdr":
                if number <= 9 { return prefix.bytes + Array(String(number).utf8) }
                // Herdr reads 1–9 off its prefix directly; past that its own tab
                // command is the honest route rather than a chord the page warns
                // "may need a custom binding".
                return Array("herdr tab focus \(number)\n".utf8)
            default:
                return nil
            }
        }

        /// Which command a two-finger swipe means, or nil to leave the swipe to the
        /// terminal.
        ///
        /// Pure and static so the mapping — including which directions are left to
        /// the terminal — can be checked without a simulator. `mux` is the host's
        /// detected kind; a host with no multiplexer has no commands at all and
        /// every direction falls through, which is what keeps two-finger scrolling
        /// working on a plain shell.
        static func matching(
            horizontal: MirrorAxis?, vertical: MirrorAxis?, mux: String?
        ) -> MuxCommand? {
            if let horizontal {
                let command: MuxCommand = horizontal == .next ? .nextPane : .previousPane
                return command.isAvailable(on: mux) ? command : nil
            }
            if let vertical {
                // Herdr has no next/previous workspace key, so its vertical swipe
                // opens the navigator instead — "drives the workspace navigator for
                // you", as Moshi documents. The others move a tab.
                let command: MuxCommand = mux == "herdr"
                    ? .workspaceNavigator
                    : (vertical == .next ? .nextTab : .previousTab)
                return command.isAvailable(on: mux) ? command : nil
            }
            return nil
        }
    }

    /// Which way along an axis a swipe went. Named for the multiplexer operation
    /// rather than the screen direction, so a caller never has to translate
    /// "left is previous".
    enum MirrorAxis: String, Codable {
        case next, previous
    }
}
