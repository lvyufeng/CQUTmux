import SwiftUI

/// What protects the key material, and what happens when the app reopens.
///
/// The screen says what is true rather than offering switches for things it
/// does not do: keys really are in the Keychain behind biometrics, and the
/// resume prompt is a real one. Where Moshi has a setting we cannot honour —
/// iCloud sync — there is no row at all, because a switch that changes nothing
/// is how a settings screen stops being worth reading.
struct SecuritySettingsView: View {
    @Environment(SecuritySettings.self) private var security
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        @Bindable var security = security
        List {
            Section {
                LabeledContent("SSH keys", value: "Keychain")
                LabeledContent("Key protection", value: Biometrics.label)
            } header: {
                Text("Storage")
            } footer: {
                Text("Private keys are held in the iOS Keychain, marked as accessible only "
                     + "while the device is unlocked and never leaving it. Passwords are "
                     + "stored the same way but read without a prompt.")
            }

            Section {
                Toggle("Require \(Biometrics.label) on reopen", isOn: $security.unlockOnResume)
                    .disabled(!security.isAvailable)
            } footer: {
                Text(security.isAvailable
                     ? "Asks for \(Biometrics.label) when the app returns from the background, "
                       + "so a handoff does not hand over the session either."
                     : "This device has no \(Biometrics.label) enrolled, so the app cannot ask "
                       + "for it. Enrol in Settings › \(Biometrics.label) & Passcode to enable this.")
            }

            Section {
                NavigationLink {
                    ExportKeysView()
                } label: {
                    Label("Exported keys", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("A private key is never shown or copied without a \(Biometrics.label) prompt.")
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Where exported key material would be listed.
///
/// Kept as an explicit, explained gap rather than a hidden one: Moshi's export
/// requires biometric confirmation, and until that path exists the honest thing
/// is to say so on the screen that claims to be about key safety.
struct ExportKeysView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Nothing exported", systemImage: "key.slash")
        } description: {
            Text("Importing a key puts it in the Keychain and keeps it there. There is no "
                 + "path yet that copies one back out, so there is nothing to list.")
        }
        .navigationTitle("Exported keys")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// iCloud settings sync.
///
/// Two switches, matching Moshi's shape: settings sync, and credential sync
/// nested beneath it. The nesting is not decoration — turning credential sync
/// on requires settings sync first, so a user cannot opt into moving secrets
/// without having opted into moving anything at all.
///
/// Moshi syncs credentials behind that second toggle. This app does not: there
/// is nowhere in the payload for them. The row is shown disabled with the
/// reason rather than hidden, because a settings screen that quietly omits a
/// feature the user expects is how they conclude the app is broken.
struct SyncSettingsView: View {
    @State private var coordinator: SettingsSyncCoordinator?
    @State private var account = true
    @State private var testing = false

    var body: some View {
        List {
            if let coordinator {
                Section {
                    @Bindable var sync = coordinator.sync
                    Toggle("Sync settings through iCloud", isOn: $sync.isEnabled)
                        .disabled(!account)
                        .onChange(of: sync.isEnabled) { _, enabled in
                            Task { await coordinator.setEnabled(enabled) }
                        }
                    LabeledContent("Status", value: coordinator.status.label)
                } footer: {
                    Text(account
                         ? "Hosts, theme, font, cursor, session layout and speech engine, kept "
                           + "in step across your devices. Nothing here is a secret: the "
                           + "payload is built field by field and has no room for one."
                         : "Sign in to iCloud in Settings to sync. Without an account the "
                           + "switch cannot do anything, so it is off for now.")
                }

                Section {
                    Toggle("Sync credentials", isOn: .constant(false))
                        .disabled(true)
                    Button("Sync now") { Task { await run(coordinator) } }
                        .disabled(!coordinator.sync.isEnabled || testing)
                } footer: {
                    Text("Not offered. Credential sync would move SSH key material and gateway "
                         + "tokens between devices, and this app keeps those in the Keychain on "
                         + "the device that created them — the host list records that a key is "
                         + "used, never the key. A switch here would move nothing.")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("iCloud sync")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard coordinator == nil else { return }
            let made = SettingsSyncCoordinator(sync: SettingsSync())
            coordinator = made
            account = await made.accountAvailable()
        }
    }

    private func run(_ coordinator: SettingsSyncCoordinator) async {
        testing = true
        defer { testing = false }
        await coordinator.run(stores: nil)
    }
}

/// The notification controls Moshi documents: an on/off, a temporary pause that
/// keeps the device registered, and a way to test that delivery works.
struct NotificationSettingsView: View {
    @Environment(SecuritySettings.self) private var security
    @State private var push = PushCoordinator.shared
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var testResult: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Permission", value: authorizationLabel)
                Toggle("Pause notifications", isOn: $push.isPaused)
            } footer: {
                Text("Pausing keeps this device registered and stops banners arriving. "
                     + "Resume whenever you like — no re-authorisation is needed.")
            }

            Section {
                Button("Send a test notification") { sendTest() }
            } footer: {
                if let testResult {
                    Text(testResult)
                } else {
                    Text("Arrives as a local notification through the same handler a "
                         + "remote one takes, so a banner appearing means the app's side "
                         + "of the path works.")
                }
            }

            Section {
                LabeledContent("Remote push", value: push.deviceToken == nil
                               ? "Not registered"
                               : "Registered")
            } footer: {
                Text("Remote delivery needs a hosted push service — APNs will not accept a "
                     + "provider JWT without a paid developer account. The gateway holds the "
                     + "token; this device never needs the signing key.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            authorization = await UNUserNotificationCenter.current().notificationSettings()
                .authorizationStatus
        }
    }

    private var authorizationLabel: String {
        switch authorization {
        case .authorized, .provisional, .ephemeral: "Allowed"
        case .denied: "Denied"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }

    private func sendTest() {
        Task {
            do {
                try await ApprovalNotifier.sendTest()
                testResult = "Sent. If no banner appears, notifications are off for the app."
            } catch {
                testResult = "Could not send: \(error.localizedDescription)"
            }
        }
    }
}