import SwiftUI
import UniformTypeIdentifiers
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
    @State private var pickingFile = false
    /// The filename of a key read from a file, kept only to be shown back. A
    /// pasted key has no name, and a row that said "Imported" for two different
    /// sources would leave the user unsure which one they used.
    @State private var importedFrom: String?

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

                Section {
                    // The file path first, because it is the one that does not
                    // involve reading a private key onto the clipboard. iOS has
                    // no clipboard-history prompt for a key copied elsewhere, so
                    // a file is both less work and less exposed.
                    Button {
                        pickingFile = true
                    } label: {
                        Label("Choose a Key File…", systemImage: "doc.badge.plus")
                    }
                    Text("~/.ssh/id_ed25519, or any file holding a private key. "
                         + "Files can read it straight from a synced folder without "
                         + "the key passing through the clipboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $importedKey)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste a Private Key") { importKey(importedKey) }
                        .disabled(importedKey.isEmpty)
                    Text("An ed25519 key in OpenSSH format (BEGIN OPENSSH PRIVATE KEY). "
                         + "Keys encrypted with a passphrase are not supported yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Import")
                } footer: {
                    if let importedFrom {
                        Text("Imported from \(importedFrom).")
                            .font(.caption)
                    }
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("SSH Key")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $pickingFile,
            allowedContentTypes: Self.keyTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                readKey(from: url)
            case .failure(let failure):
                // A cancelled picker also lands here on some iOS versions, and
                // reporting "cancelled" as an error would be noise.
                if (failure as NSError).code != NSUserCancelledError {
                    error = failure.localizedDescription
                }
            }
        }
        .task { loadExisting() }
    }

    /// What the picker will accept.
    ///
    /// `public.plain-text` is there for the same reason the file is offered at
    /// all: a private key copied out of `~/.ssh` is frequently named with no
    /// extension, and an extension-only filter would grey it out and leave the
    /// user thinking the file was the problem. The parse is the real gate.
    private static var keyTypes: [UTType] {
        var types: [UTType] = [.plainText, .data]
        if let item = UTType(filenameExtension: "key") { types.insert(item, at: 0) }
        if let pem = UTType(filenameExtension: "pem") { types.insert(pem, at: 0) }
        return types
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

    private func importKey(_ pem: String) {
        do {
            let seed = try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: pem)
            KeychainStore.save(seed, account: host.keySeedAccount)
            publicKey = try Ed25519OpenSSH.publicKey(fromSeed: seed, comment: host.displayName)
            importedKey = ""
            importedFrom = nil
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    /// Reads a key file and imports it.
    ///
    /// The security-scoped access is opened and closed around the whole read
    /// rather than around the import: a URL from the document picker is only
    /// valid inside that window, and the import is cheap enough to sit within
    /// it. Files outside the app's container — which `~/.ssh` in a synced
    /// folder is — fail without it, and fail with a permission error that reads
    /// as a corrupt key.
    private func readKey(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            importKey(text)
            // Only name the file as the source if the parse actually took:
            // "imported from id_ed25519" sitting under an error message is the
            // one combination that would make the user stop looking.
            if error == nil { importedFrom = url.lastPathComponent }
        } catch {
            self.error = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}