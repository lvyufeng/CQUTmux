import SwiftUI
import LocalAuthentication
import CQUTTransport

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
                Toggle("Let sessions read the clipboard", isOn: $security.allowsClipboardRead)
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Programs on the host can always *write* to this device's clipboard "
                     + "(OSC 52 copy). This allows the other direction: a program may ask "
                     + "for whatever is on it. That request comes from the remote side with "
                     + "no gesture here, so with it on, anything running in a session can "
                     + "read a password or a code you copied. Off unless you are running "
                     + "something that needs it.")
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

/// Copying a private key back out of the app.
///
/// Held shut until a biometric prompt passes, and the prompt is the point
/// rather than a formality: an unlocked phone in someone else's hand should not
/// be enough to walk off with the key that reaches every host.
///
/// The export is the app's own created/imported key, re-emitted as an
/// unencrypted `openssh-key-v1` PEM. It is deliberately unencrypted — the app
/// holds a bare seed and has no passphrase to encrypt with — so this is a
/// portability escape hatch, and the screen says so instead of implying the
/// output is protected.
struct ExportKeysView: View {
    @Environment(HostStore.self) private var hosts

    @State private var unlocked = false
    @State private var busy = false
    @State private var failure: String?
    @State private var exported: (host: Host, pem: String)?
    @State private var copied = false

    /// Only hosts that actually have a key. A host seen but never connected to
    /// has nothing to export, and listing it would produce an empty PEM.
    private var keyed: [Host] {
        hosts.hosts.filter { KeychainStore.load(account: $0.keySeedAccount) != nil }
    }

    var body: some View {
        List {
            if !Biometrics.isEnrolled {
                Section {
                    ContentUnavailableView {
                        Label("Biometrics are not set up", systemImage: "faceid")
                    } description: {
                        Text("Exporting a private key needs \(Biometrics.label). "
                             + "Enroll in Settings → Face ID & Passcode, then come back.")
                    }
                }
            } else if keyed.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No keys to export", systemImage: "key.slash")
                    } description: {
                        Text("A host gets a key when you generate or import one from "
                             + "its SSH Key screen.")
                    }
                }
            } else if !unlocked {
                Section {
                    Button {
                        Task { await unlock() }
                    } label: {
                        Label(busy ? "Waiting for \(Biometrics.label)…" : "Unlock to export",
                              systemImage: "faceid")
                    }
                    .disabled(busy)
                } footer: {
                    Text("Nothing can be copied out until \(Biometrics.label) confirms it is you.")
                }
            } else if let exported {
                Section {
                    Text(exported.pem)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = exported.pem
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy key", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button("Hide", role: .destructive) {
                        self.exported = nil
                        copied = false
                    }
                } header: {
                    Text("\(exported.host.displayName) — private key")
                } footer: {
                    Text("Unencrypted. Anything holding this text can log in as this key, "
                         + "so put it somewhere safe and clear the clipboard when done.")
                }
            } else {
                Section {
                    ForEach(keyed) { host in
                        Button {
                            export(for: host)
                        } label: {
                            HStack {
                                Label(host.displayName, systemImage: "key.horizontal")
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Unencrypted OpenSSH format, for a machine that cannot scan a QR code.")
                        .font(.caption)
                }
            }

            if let failure {
                Section { Text(failure).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("Exported keys")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func unlock() async {
        busy = true
        defer { busy = false }
        let context = LAContext()
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Export a private SSH key"
            )
            if ok { unlocked = true; failure = nil }
        } catch {
            // A cancelled or failed read is not an error to shout about — the
            // button is still there and the user can press it again.
            failure = nil
        }
    }

    private func export(for host: Host) {
        guard let seed = KeychainStore.load(account: host.keySeedAccount) else {
            failure = "No key is stored for \(host.displayName)."
            return
        }
        do {
            let pem = try Ed25519OpenSSH.openSSHPrivateKey(fromSeed: seed, comment: host.displayName)
            exported = (host, pem)
            failure = nil
        } catch {
            failure = "Could not write the key: \(error)"
        }
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