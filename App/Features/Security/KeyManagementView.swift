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
    /// The passphrase the user typed for an encrypted key. Held only in
    /// memory until they tap Import, so a passphrase for a key they decide not
    /// to import is never written anywhere.
    @State private var importPassphrase = ""
    /// Whether the key typed or chosen is encrypted. Set by a trial parse with
    /// no passphrase, which is the only way to tell without asking the user to
    /// declare it.
    @State private var keyIsEncrypted = false

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
                        .onChange(of: importedKey) { _, text in
                            keyIsEncrypted = Self.looksEncrypted(text)
                        }
                    if keyIsEncrypted {
                        SecureField("Key passphrase", text: $importPassphrase)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("This key is encrypted. Its passphrase is stored in the Keychain "
                             + "with it, so the key cannot be opened from an unlocked backup alone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Import Private Key") { importKey(importedKey, passphrase: importPassphrase) }
                        .disabled(importedKey.isEmpty)
                    Text("An ed25519 key in OpenSSH format (BEGIN OPENSSH PRIVATE KEY), "
                         + "encrypted with a passphrase or not.")
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
            // A generated key has no passphrase, so a stored one is now stale
            // and would be offered up the next time this key is unlocked.
            KeychainStore.delete(account: host.keyPassphraseAccount)
            publicKey = line
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    /// Whether a private key is encrypted, decided by trying it rather than by
    /// reading its header.
    ///
    /// The header would say (`aes256-ctr`/`bcrypt`), but reaching into the
    /// container to read two strings duplicates a parser that already exists,
    /// and this way the answer is exactly "does a passphrase change the
    /// outcome" — which is the question the UI is asking.
    static func looksEncrypted(_ pem: String) -> Bool {
        guard pem.contains("BEGIN OPENSSH PRIVATE KEY") else { return false }
        do {
            _ = try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: pem, passphrase: "")
            return false
        } catch let error as Ed25519OpenSSH.KeyError {
            return String(describing: error).lowercased().contains("passphrase")
        } catch {
            return false
        }
    }

    /// Imports a key, storing it in the form it arrived in.
    ///
    /// An unencrypted key is reduced to its seed, as before: there is no
    /// passphrase protecting it and keeping the PEM would only be a bigger
    /// thing to store. An encrypted one is kept *encrypted*, with the
    /// passphrase beside it in the Keychain, so the passphrase remains a real
    /// second factor rather than a ceremony performed once at import.
    private func importKey(_ pem: String, passphrase: String) {
        do {
            let seed = try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: pem, passphrase: passphrase)
            if passphrase.isEmpty {
                KeychainStore.save(seed, account: host.keySeedAccount)
                KeychainStore.delete(account: host.keyPassphraseAccount)
            } else {
                KeychainStore.save(Data(pem.utf8), account: host.keySeedAccount)
                KeychainStore.save(Data(passphrase.utf8), account: host.keyPassphraseAccount)
            }
            publicKey = try Ed25519OpenSSH.publicKey(fromSeed: seed, comment: host.displayName)
            importedKey = ""
            importPassphrase = ""
            keyIsEncrypted = false
            importedFrom = nil
            error = nil
        } catch {
            // A wrong passphrase and a corrupt key both land here. The parse
            // error already distinguishes them — the reader reports "the
            // passphrase did not decrypt this key" when the container was
            // readable and the passphrase was wrong — so the message is passed
            // through rather than replaced.
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
            keyIsEncrypted = Self.looksEncrypted(text)
            if keyIsEncrypted && importPassphrase.isEmpty {
                // Put the key in the editor and stop, rather than importing and
                // failing. A chosen file is the path most users take, and
                // failing here would leave them with an error and no way to
                // supply the passphrase — the file picker would have to be
                // opened a second time for no reason.
                importedKey = text
                importedFrom = url.lastPathComponent
                error = nil
                return
            }
            importKey(text, passphrase: importPassphrase)
            // Only name the file as the source if the parse actually took:
            // "imported from id_ed25519" sitting under an error message is the
            // one combination that would make the user stop looking.
            if error == nil { importedFrom = url.lastPathComponent }
        } catch {
            self.error = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}