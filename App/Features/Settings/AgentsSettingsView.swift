import SwiftUI

/// Settings → Agents: the app-wide preferences for watching agents.
struct AgentsSettingsView: View {
    @Environment(AppSettings.self) private var app

    var body: some View {
        @Bindable var app = app
        List {
            Section {
                Toggle("Keep screen on", isOn: $app.keepScreenOn)
            } header: {
                Label("Display", systemImage: "sun.max")
            } footer: {
                Text("While the Agents screen is in front, stop the display from sleeping. "
                     + "For a phone propped up next to a keyboard; it is what stops the "
                     + "screen locking between two approvals. It is released the moment "
                     + "you leave the screen.")
            }

            Section {
                // A stepper over a field: the useful values are a handful of
                // round numbers, and typing 200000 on a phone keyboard is worse
                // than four taps. Zero is a real choice — it turns the ring off
                // — and the label says so rather than leaving an unexplained 0.
                Stepper(value: $app.contextLimit, in: 0...2_000_000, step: 50_000) {
                    LabeledContent("Context window", value: contextLabel)
                }
            } header: {
                Label("Inbox", systemImage: "tray.full")
            } footer: {
                Text("The Inbox ring shows how full an agent's context window is, read "
                     + "from its own session log. The log records how many tokens each "
                     + "turn used but never how many fit, so this number is an "
                     + "assumption — set it to your model's window. Zero hides the ring.")
            }

            Section {
                Toggle("Hide the Code tab", isOn: $app.hidesCodeTab)
                Toggle("Hide the Files panel", isOn: $app.hidesFiles)
                    .disabled(app.hidesCodeTab)
            } header: {
                Label("Home screen", systemImage: "square.grid.2x2")
            } footer: {
                Text("The first takes the Code tab off the tab bar entirely. The second "
                     + "keeps the tab but drops its Files mode, for when the diff and the "
                     + "transcript are useful and browsing the tree is not.")
            }
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "200k tokens", or "Hidden" for zero. A plain `0` in the row reads as a
    /// value nobody set rather than as the switch it is.
    private var contextLabel: String {
        guard app.contextLimit > 0 else { return "Hidden" }
        let thousands = Double(app.contextLimit) / 1000
        // "200k" rather than "200.0k": the round numbers are the ones people
        // set, and the decimal is noise on all of them.
        let text = thousands == thousands.rounded()
            ? "\(Int(thousands))k"
            : String(format: "%.1fk", thousands)
        return "\(text) tokens"
    }
}

#Preview {
    NavigationStack { AgentsSettingsView() }
        .environment(AppSettings())
}