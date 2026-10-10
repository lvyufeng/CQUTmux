import SwiftUI

/// Settings → Integrations. The options that change something on the *host*
/// rather than in the app: the client marker an rc file can branch on, and the
/// locale the session runs under.
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

            Section {
                TextField("Leave empty for the host's own locale", text: $integrations.locale)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))

                // The model drops a locale it cannot safely send. Saying so here
                // is the difference between "the setting does nothing" and "the
                // setting is doing nothing, and here is why" — the check covers
                // the dropping, and only the screen can cover the telling.
                if !integrations.locale.isEmpty,
                   !IntegrationSettings.isExportableLocale(integrations.locale) {
                    Label(
                        "Not a UTF-8 locale name — nothing will be sent.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } header: {
                Label("Locale", systemImage: "globe")
            } footer: {
                Text(localeFooter)
            }
        }
        .navigationTitle("Integrations")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The locale field's explanation. Kept out of the `body` for the same
    /// reason as `footer`.
    private var localeFooter: String {
        "Sets LANG and LC_ALL in every session, so the host renders UTF-8 output "
            + "— box-drawing, CJK and emoji — instead of escaping it. Empty by "
            + "default: a locale the host does not have installed makes every "
            + "command print a setlocale warning, so turning this on is a choice "
            + "rather than a default. Most hosts have en_US.UTF-8; every libc has "
            + "C.UTF-8. A value that is not a UTF-8 locale is ignored rather than "
            + "sent. SSH and Mosh sessions honour it; Eternal Terminal cannot."
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