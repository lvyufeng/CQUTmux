import SwiftUI

struct HostEditView: View {
    @State var host: Host
    var onSave: (Host) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Held in a local @State rather than the struct so the plaintext never
    /// travels with the persisted Host.
    @State private var gatewayToken = ""
    /// Whether a key is in the Keychain for this host. Loaded once in `task`.
    @State private var hasKey = false

    private var saveDisabled: Bool {
        host.hostname.isEmpty
    }

    var body: some View {
        Form {
            Section("Host") {
                TextField("Name", text: $host.name)
                TextField("Hostname or IP", text: $host.hostname)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Username", text: $host.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("22", value: $host.port, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .frame(maxWidth: 80)
                }
            }

            Section("Connection") {
                Picker("Type", selection: $host.transport) {
                    ForEach(TransportKind.allCases) { Text($0.label).tag($0) }
                }
                Text(host.transport.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Mosh needs a program on the host that SSH alone does not
                // require, so say so up front rather than letting the session
                // fail with a half-explained message. `auto` hides this, and
                // that is the point of `auto` — it falls back on its own.
                if host.transport == .mosh {
                    Label("Needs mosh-server on the host. The RTT-adaptive UDP session starts once it is running.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // ET needs a program on the host just as mosh does, and it is the one
                // to reach for when mosh's UDP is blocked: ET is TCP, on the port
                // below, over a connection the host is already reachable on.
                if host.transport == .et {
                    Label("Needs etterminal on the host. TCP, so it works where mosh's UDP is blocked.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if host.transport == .auto {
                    Label("Tries mosh, then ET if the host has no mosh-server, then SSH.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if host.transport == .ssh || host.transport == .auto {
                    TextField("Jump host (user@host:22)", text: Binding(
                        get: { host.jumpHost ?? "" },
                        set: { host.jumpHost = $0.isEmpty ? nil : $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    // The hop authenticates with the same key or password saved
                    // for the target, so say that rather than letting a
                    // mismatch look like a broken jump host.
                    if host.jumpHost?.isEmpty == false {
                        Text("Connects to the target through this host, using the same credentials.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if host.transport == .mosh {
                    TextField("Mosh UDP port range (e.g. 60000:61000)", text: Binding(
                        get: { host.moshPortRange ?? "" },
                        set: { host.moshPortRange = $0.isEmpty ? nil : $0 }
                    ))
                    .textInputAutocapitalization(.never)
                }

                if host.transport == .et {
                    HStack {
                        Text("ET TCP port")
                        Spacer()
                        TextField("2022", value: Binding(
                            get: { host.etPort ?? 2022 },
                            set: { host.etPort = $0 }
                        ), format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .frame(maxWidth: 80)
                    }
                }
            }

            Section("Authentication") {
                Picker("Method", selection: $host.authMethod) {
                    ForEach(AuthMethod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if host.authMethod == .key {
                    // Read the key's presence from the Keychain, which is
                    // where it actually lives — the Host struct carries no
                    // reference to it.
                    LabeledContent(
                        "Private key",
                        value: hasKey ? "In Keychain" : "None"
                    )
                    Text("Import an Ed25519 key from Settings, then unlock it with Face ID when connecting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if host.transport == .ssh && host.authMethod == .key {
                    Toggle("Forward SSH Agent", isOn: $host.forwardAgent)

                    // swift-nio-ssh has no channel for agent forwarding yet, and
                    // we have no ssh-agent socket to forward to on iOS anyway.
                    if host.forwardAgent {
                        Label("Not available yet — the app keeps the key to itself.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Session") {
                TextField("Startup command", text: $host.sessionCommand)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            }

            Section {
                TextField("24543", value: $host.gatewayPort, format: .number)
                    .keyboardType(.numberPad)
                SecureField("Token (if the gateway sets one)", text: $gatewayToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Agent Gateway")
            } footer: {
                Text("The gap between this port on the host and nothing on the network: the gateway listens on loopback and the app reaches it through the SSH channel. Set a token to match cqutmux-hook --token.")
                    .font(.caption)
            }
        }
        .navigationTitle(host.name.isEmpty ? "New Host" : host.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            gatewayToken = KeychainStore.load(account: host.gatewayTokenAccount)
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            hasKey = KeychainStore.load(account: host.keySeedAccount) != nil
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if gatewayToken.isEmpty {
                        KeychainStore.delete(account: host.gatewayTokenAccount)
                    } else if let data = gatewayToken.data(using: .utf8) {
                        _ = KeychainStore.save(data, account: host.gatewayTokenAccount)
                    }
                    onSave(host)
                    dismiss()
                }
                .disabled(saveDisabled)
            }
        }
    }
}

#Preview {
    NavigationStack {
        HostEditView(host: Host()) { _ in }
    }
}