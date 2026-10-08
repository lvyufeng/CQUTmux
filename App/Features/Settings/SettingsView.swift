import SwiftUI

struct SettingsView: View {
    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CQUT_DEV_TAB"] == "theme" {
            return AnyView(ThemeSettingsView())
        }
        if ProcessInfo.processInfo.environment["CQUT_DEV_TAB"] == "font" {
            return AnyView(FontSettingsView())
        }
        #endif
        return AnyView(list)
    }

    private var list: some View {
        List {
            Section("Security") {
                Label("SSH keys in Keychain", systemImage: "key.fill")
                Label("Face ID unlock", systemImage: "faceid")
            }
            Section("Appearance") {
                NavigationLink {
                    ThemeSettingsView()
                } label: {
                    Label("Theme", systemImage: "paintpalette")
                }
                NavigationLink {
                    FontSettingsView()
                } label: {
                    Label("Font", systemImage: "textformat.size")
                }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.appVersion)
                LabeledContent("Hook gateway", value: "127.0.0.1:24543")
            }
        }
        .navigationTitle("Settings")
    }
}

private extension Bundle {
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }
}

#Preview {
    NavigationStack { SettingsView() }
}