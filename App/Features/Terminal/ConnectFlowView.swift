import SwiftUI
import LocalAuthentication
import CQUTTransport

/// Resolves credentials for a host, prompting when nothing is stored, then
/// hands off to the live terminal.
struct ConnectFlowView: View {
    @Environment(ThemeStore.self) private var themes
    let host: Host
    /// A link that opened this screen. Carries the session to attach to once
    /// the terminal is actually up.
    var link: DeepLink? = nil

    @State private var credential: SSHCredential?
    @State private var password = ""
    @State private var error: String?
    /// Set when the stored key is an encrypted snapshot that needs its
    /// passphrase before it can be used. See `resolveSeed`.
    @State private var needsPassphrase = false
    @State private var passphrase = ""

    var body: some View {
        Group {
            if let credential {
                TerminalScreen(host: host, credential: credential, link: link)
            } else {
                prompt
            }
        }
        .task { await resolveStoredCredential() }
    }

    private var prompt: some View {
        Form {
            Section {
                LabeledContent("Host", value: host.target)
                LabeledContent("Port", value: "\(host.port)")
                LabeledContent("Transport", value: host.transport.label)
            }
            if host.authMethod == .password {
                Section("Password") {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    Toggle("Remember in Keychain", isOn: $remember).tint(themes.current.accentColor)
                }
            } else {
                Section("SSH Key") {
                    NavigationLink {
                        KeyManagementView(host: host)
                    } label: {
                        Label("Manage Key", systemImage: "key.horizontal")
                    }
                    if KeychainStore.load(account: host.keySeedAccount) == nil {
                        Text("No key yet — generate or import one, then add the public line to the server.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if needsPassphrase {
                        SecureField("Key passphrase", text: $passphrase)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("Remember in Keychain", isOn: $rememberPassphrase)
                            .tint(themes.current.accentColor)
                        Text("This key was imported while encrypted. The passphrase unlocks it "
                             + "on this device; it is never sent anywhere.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                Button("Connect") { Task { await connect() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(host.authMethod == .password && password.isEmpty)
            }
        }
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.inline)
    }

    @State private var remember = true
    @State private var rememberPassphrase = true

    private func resolveStoredCredential() async {
        switch host.authMethod {
        case .password:
            if let data = KeychainStore.load(account: host.passwordAccount),
               let stored = String(data: data, encoding: .utf8) {
                credential = .password(stored)
            }
        case .key:
            // The stored passphrase is read here rather than kept in state:
            // `@State` survives longer than the screen, and a passphrase that
            // outlives the prompt is one sitting in memory for no reason.
            //
            // Deliberately *not* preceded by a call to `KeyMaterial.requirement`:
            // that would run the bcrypt derivation once to decide, and then
            // `unlock` would run it again to actually open the key. Asking the
            // question and acting on it are the same work here — `unlock` sets
            // `needsPassphrase` on failure — so the decision is made by trying.
            let stored = KeychainStore.load(account: host.keyPassphraseAccount)
                .flatMap { String(data: $0, encoding: .utf8) }
            await unlock(using: stored, interactive: false)
        }
    }

    /// Opens the stored key and hands the seed to the terminal.
    ///
    /// `interactive` is false on the automatic path: there is nothing the user
    /// typed on the first pass, so a failure only reveals the passphrase field
    /// rather than reporting an error the user did not cause.
    private func unlock(using available: String?, interactive: Bool) async {
        let data = KeychainStore.load(account: host.keySeedAccount)
        do {
            let seed = try KeyMaterial.seed(from: data, passphrase: available)
            needsPassphrase = false
            await authenticateThen { credential = .ed25519Seed(seed) }
        } catch {
            // Not necessarily an error: needing to ask for a passphrase is the
            // ordinary case and reaches here. `interactive` distinguishes it,
            // because on the automatic pass a message would appear under a
            // field the user has not been given yet.
            needsPassphrase = true
            credential = nil
            if interactive { self.error = "\(error)" }
        }
    }

    private func connect() async {
        switch host.authMethod {
        case .password:
            if remember {
                KeychainStore.save(Data(password.utf8), account: host.passwordAccount)
            }
            credential = .password(password)
        case .key:
            if needsPassphrase {
                // Remembering is the whole point of the field: without it the
                // prompt returns on every connect, which is fine for a key used
                // once and unbearable for one used hourly.
                if rememberPassphrase {
                    KeychainStore.save(Data(passphrase.utf8), account: host.keyPassphraseAccount)
                } else {
                    KeychainStore.delete(account: host.keyPassphraseAccount)
                }
                await unlock(using: passphrase, interactive: true)
            } else {
                let stored = KeychainStore.load(account: host.keyPassphraseAccount)
                    .flatMap { String(data: $0, encoding: .utf8) }
                await unlock(using: stored, interactive: true)
            }
        }
    }

    private func authenticateThen(_ action: @escaping () -> Void) async {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError) else {
            #if DEBUG
            // Simulators without enrolled biometrics can't evaluate the policy.
            // Debug builds proceed so UI runs stay usable; release does not.
            if ProcessInfo.processInfo.environment["CQUT_DEV_HOST"] != nil {
                action()
                return
            }
            #endif
            error = "Biometrics unavailable: \(policyError?.localizedDescription ?? "unknown")"
            return
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock the SSH key for \(host.displayName)"
            )
            if ok { action() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}