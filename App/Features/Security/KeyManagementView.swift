import SwiftUI
import CQUTTransport

/// Generate or import an ed25519 key for a host, and show the public line to
/// paste into the server's `authorized_keys`. Only the 32-byte seed is stored,
/// in the Keychain; the OpenSSH blob never touches disk.
struct KeyManagementView: View {
    let host: Host

    @State private var publicKey: String?
    @State private var importedKey = ""
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        Form {
            if let publicKey {
                Section("Public Key") {
                    Text(publicKey)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = publicKey
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Text("Add this line to ~/.ssh/authorized_keys on the host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("No key yet") {
                    Button {
                        generate()
                    } label: {
                        Label("Generate New Key", systemImage: "key.horizontal")
                    }
                }

                Section("Import") {
                    TextEditor(text: $importedKey)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Import Private Key") { importKey() }
                        .disabled(importedKey.isEmpty)
                    Text("Paste an unencrypted ed25519 private key (BEGIN OPENSSH PRIVATE KEY).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("SSH Key")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadExisting() }
    }

    private func loadExisting() {
        guard let seed = KeychainStore.load(account: host.keySeedAccount) else { return }
        publicKey = try? Ed25519OpenSSH.publicKey(fromSeed: seed, comment: host.displayName)
    }

    private func generate() {
        do {
            let (seed, line) = try Ed25519OpenSSH.generate()
            KeychainStore.save(seed, account: host.keySeedAccount)
            publicKey = line
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    private func importKey() {
        do {
            let seed = try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: importedKey)
            KeychainStore.save(seed, account: host.keySeedAccount)
            publicKey = try Ed25519OpenSSH.publicKey(fromSeed: seed, comment: host.displayName)
            importedKey = ""
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}