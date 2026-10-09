import SwiftUI

/// Settings → Integrations. One section, because one integration option
/// changes anything on the host.
struct IntegrationSettingsView: View {
    @State private var integrations = IntegrationSettings()

    var body: some View {
        List {
            Section {
                Toggle("Export client environment", isOn: $integrations.exportClientEnv)
            } header: {
                Label("Shell", systemImage: "terminal")
            } footer: {
                Text(footer)
            }

            if integrations.exportClientEnv {
                Section("On the host") {
                    CodeLine("if [ -n \"$\(IntegrationSettings.variable)\" ]; then")
                    CodeLine("  # driven from the app — trim prompts, skip glyphs…")
                    CodeLine("fi")
                    CodeLine("")
                    CodeLine("# ~/.tmux.conf: keep the variable across a tmux attach")
                    CodeLine("set-option -ga update-environment \" \(IntegrationSettings.variable)\"")
                }
            }
        }
        .navigationTitle("Integrations")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Kept out of the `body`: the interpolations and the concatenation together
    /// are more than the type checker will take on inside a view builder.
    private var footer: String {
        let name = IntegrationSettings.variable
        return "Sets \(name)=1 in every session this app opens, so an rc file, "
            + "prompt or tmux config on the host can tell it is being driven from "
            + "here and adapt. Off by default; the variable is only present in "
            + "sessions opened after you turn it on. SSH and Mosh sessions honour "
            + "it; Eternal Terminal cannot — its protocol carries no environment "
            + "of its own — so an ET session will not see it."
    }
}

/// A line of shell as it is meant to be read, offered for copying. Text rather
/// than a TextEditor: nothing here is meant to be edited, and a selectable
/// monospaced line is easier to copy from a phone than a field.
private struct CodeLine: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}