import SwiftUI

struct HostEditView: View {
    @State var host: Host
    var onSave: (Host) -> Void

    @Environment(\.dismiss) private var dismiss

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
        }
        .navigationTitle(host.name.isEmpty ? "New Host" : host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(host)
                    dismiss()
                }
                .disabled(host.hostname.isEmpty)
            }
        }
    }
}

#Preview {
    NavigationStack {
        HostEditView(host: Host()) { _ in }
    }
}