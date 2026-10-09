import SwiftUI

/// Settings → Multiplexer: the one thing this client has to know about the
/// host's own tmux configuration.
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
                Text(footer)
            }

            Section {
                LabeledContent("tmux.conf", value: "set -g prefix \(mux.tmuxPrefix.configSpelling)")
            } header: {
                Text("What to look for")
            } footer: {
                Text("If your tmux reports a different prefix at the bottom of the "
                     + "screen when you press it, this is the line to change.")
            }
        }
        .navigationTitle("Multiplexer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footer: String {
        "Jump-To and the keyboard's window shortcuts open a window by sending this "
        + "key, so tmux reads the command rather than it being typed into a pane an "
        + "agent may be busy in. It has to match the host: with the wrong prefix the "
        + "keystroke does nothing to tmux and the digit lands in the running program. "
        + "zellij and herdr do not use a prefix and are unaffected."
    }
}