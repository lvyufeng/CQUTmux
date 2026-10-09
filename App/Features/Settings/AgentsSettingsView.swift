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
                Toggle("Hide the Code tab", isOn: $app.hidesCodeTab)
            } header: {
                Label("Home screen", systemImage: "square.grid.2x2")
            } footer: {
                Text("Takes the Code tab off the tab bar (and the sidebar). The Files, "
                     + "Changes, History and Chat panels live there; if you never open "
                     + "them, this gives the rest of the bar more room.")
            }
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { AgentsSettingsView() }
        .environment(AppSettings())
}