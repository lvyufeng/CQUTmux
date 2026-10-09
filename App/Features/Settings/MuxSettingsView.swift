import SwiftUI

/// Settings → Multiplexer: the keys this client has to know about the host's
/// own tmux and herdr configuration.
///
/// tmux and herdr are separate programs with separate configuration files, so
/// they get separate prefixes. A host often runs both — tmux inside a herdr
/// pane is the usual shape — and a single shared setting would be wrong for
/// whichever of the two the user had rebound.
struct MuxSettingsView: View {
    @State private var mux = MuxSettings()

    var body: some View {
        @Bindable var mux = mux
        List {
            Section {
                Picker("Prefix", selection: $mux.tmuxPrefix) {
                    ForEach(MuxSettings.Prefix.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Label("tmux prefix", systemImage: "coloncurrencysign.circle")
            } footer: {
                Text(tmuxFooter)
            }

            Section {
                LabeledContent("tmux.conf", value: "set -g prefix \(mux.tmuxPrefix.configSpelling)")
            } header: {
                Text("What to look for")
            } footer: {
                Text("If your tmux reports a different prefix at the bottom of the "
                     + "screen when you press it, this is the line to change.")
            }

            Section {
                Picker("Prefix", selection: $mux.herdrPrefix) {
                    ForEach(MuxSettings.Prefix.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Label("herdr prefix", systemImage: "rectangle.3.group")
            } footer: {
                Text(herdrFooter)
            }

            Section {
                ForEach(herdrShortcuts, id: \.keys) { shortcut in
                    LabeledContent(shortcut.keys) { Text(shortcut.action) }
                }
            } header: {
                Text("herdr shortcuts")
            } footer: {
                Text("These are herdr's own defaults. Two-finger swipes and a pinch "
                     + "send them from the terminal; they are listed here so what a "
                     + "gesture did is something you can see rather than infer. If you "
                     + "have rebound them in ~/.config/herdr/config, rebind the "
                     + "gestures to match under Settings → Input → Gestures.")
            }
        }
        .navigationTitle("Multiplexer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var tmuxFooter: String {
        "Jump-To and the keyboard's window shortcuts open a window by sending this "
        + "key, so tmux reads the command rather than it being typed into a pane an "
        + "agent may be busy in. It has to match the host: with the wrong prefix the "
        + "keystroke does nothing to tmux and the digit lands in the running program. "
        + "zellij uses no prefix and is unaffected."
    }

    private var herdrFooter: String {
        "The two-finger swipes and a pinch send herdr's own keys, so this has to be "
        + "the prefix in your ~/.config/herdr/config — herdr defaults to Ctrl-B, the "
        + "same as tmux, but the two are configured separately and changing one does "
        + "not change the other. zellij uses no prefix and is unaffected."
    }

    /// herdr's published defaults, shown with this user's prefix in front.
    private var herdrShortcuts: [(keys: String, action: String)] {
        let prefix = mux.herdrPrefix.label
        return [
            (prefix + " n", "Next tab"),
            (prefix + " p", "Previous tab"),
            (prefix + " j", "Next pane"),
            (prefix + " k", "Previous pane"),
            (prefix + " z", "Zoom the focused pane"),
            (prefix + " w", "Workspaces (two-finger up/down)"),
            (prefix + " g", "Goto prompt"),
        ]
    }
}