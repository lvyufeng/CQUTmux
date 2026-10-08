import SwiftUI
import LocalAuthentication
import CQUTTransport

/// Resolves credentials for a host, prompting when nothing is stored, then
/// hands off to the live terminal.
struct ConnectFlowView: View {
    let host: Host

    @State private var credential: SSHCredential?
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        Group {
            if let credential {
                TerminalScreen(host: host, credential: credential)
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
                    Toggle("Remember in Keychain", isOn: $remember).tint(Theme.accent)
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

    private func resolveStoredCredential() async {
        switch host.authMethod {
        case .password:
            if let data = KeychainStore.load(account: host.passwordAccount),
               let stored = String(data: data, encoding: .utf8) {
                credential = .password(stored)
            }
        case .key:
            if let seed = KeychainStore.load(account: host.keySeedAccount) {
                await authenticateThen { credential = .ed25519Seed(seed) }
            }
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
            guard let seed = KeychainStore.load(account: host.keySeedAccount) else {
                error = "No key imported yet. Key import lands in a follow-up commit."
                return
            }
            await authenticateThen { credential = .ed25519Seed(seed) }
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