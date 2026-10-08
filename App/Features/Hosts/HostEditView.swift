import SwiftUI

struct HostEditView: View {
    @State var host: Host
    var onSave: (Host) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Held in a local @State rather than the struct so the plaintext never
    /// travels with the persisted Host.
    @State private var gatewayToken = ""

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

                // Mosh and ET aren't wired up yet (their C/C++ dependencies
                // don't cross-compile in this project's toolchain). Say so
                // rather than letting the host silently behave like plain SSH.
                if host.transport == .mosh || host.transport == .et {
                    Label("Not available yet — this host will connect over SSH.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if host.transport == .ssh || host.transport == .auto {
                    TextField("Jump host (user@host:22)", text: Binding(
                        get: { host.jumpHost ?? "" },
                        set: { host.jumpHost = $0.isEmpty ? nil : $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                    LabeledContent("Private key", value: host.keyIdentifier == nil ? "None" : "In Keychain")
                    Text("Key import and Face ID unlock arrive in Phase 1.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if host.transport == .ssh && host.authMethod == .key {
                    Toggle("Forward SSH Agent", isOn: $host.forwardAgent)
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