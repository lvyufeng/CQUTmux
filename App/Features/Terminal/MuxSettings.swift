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

    init(store: UserDefaults = .standard) {
        self.store = store
        tmuxPrefix = Prefix.named(store.string(forKey: Key.tmuxPrefix))
    }
}