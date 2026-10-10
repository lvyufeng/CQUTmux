import SwiftUI
import WebKit

/// Browser preview of a dev server running on the host. Mirrors Moshi's
/// preview pane: pick a listening port, and the app loads it as if it were
/// local — the bytes actually travel through the SSH tunnel.
struct PreviewView: View {
    @Environment(ThemeStore.self) private var themes
    let client: HookClient

    @Environment(\.dismiss) private var dismiss

    @State private var port: Int?
    @State private var typedPort = ""
    @State private var board: PortBoard?
    @State private var bridge: PreviewBridge?
    @State private var localPort: Int?
    @State private var error: String?
    @State private var loadingPorts = true

    var body: some View {
        NavigationStack {
            Group {
                if let localPort {
                    WebView(url: URL(string: "http://127.0.0.1:\(localPort)"))
                        .ignoresSafeArea(.container, edges: .bottom)
                } else if let error {
                    ContentUnavailableView {
                        Label("Can't preview", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        portField
                    }
                } else {
                    portPicker
                }
            }
            .navigationTitle(port.map { "Preview :\(String($0))" } ?? "Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Label("Ports", systemImage: "arrow.clockwise")
                    }
                }
            }
            .task { await loadPorts() }
            .onDisappear { bridge?.stop() }
            #if DEBUG
            .task {
                // UI runs can jump straight to a port to exercise the bridge.
                if let raw = ProcessInfo.processInfo.environment["CQUT_DEV_PREVIEW_PORT"],
                   let value = Int(raw), localPort == nil, port == nil {
                    open(value)
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private var portPicker: some View {
        List {
            Section {
                portField
            } header: {
                Text("Port on the host")
            } footer: {
                Text("Pick a port your dev server is listening on. It's reached through the SSH session — the host's gateway lists what's open.")
            }

            if loadingPorts {
                HStack { ProgressView(); Text("Looking for listening ports…") }
            } else if let listeners = board?.listeners, !listeners.isEmpty {
                Section("Listening now") {
                    ForEach(listeners) { listener in
                        Button {
                            open(listener.port)
                        } label: {
                            HStack {
                                Text(verbatim: String(listener.port))
                                    .font(.system(.body, design: .monospaced))
                                if let name = Self.describe(listener) {
                                    Text(name)
                                        .font(.caption2)
                                        .foregroundStyle(themes.current.accentColor)
                                        .lineLimit(1)
                                }
                                Spacer()
                                // A loopback-only server is not reachable through
                                // the SSH session, so the port being open is not
                                // the whole story and saying so is the difference
                                // between "connection refused" and a reason.
                                if listener.scope == "loopback" {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .accessibilityLabel("host-local only")
                                }
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            } else if let board, !board.available {
                Text(board.error ?? "Port listing unavailable on this host.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var portField: some View {
        HStack {
            TextField("3000", text: $typedPort)
                .keyboardType(.numberPad)
                .font(.system(.body, design: .monospaced))
            Button("Open") {
                if let value = Int(typedPort) { open(value) }
            }
            .disabled(Int(typedPort) == nil)
        }
    }

    private func open(_ candidate: Int) {
        port = candidate
        // The bridge needs the transport, which only exists once connected.
        guard let transport = client.forwardTransport() else {
            error = "Not connected to the host."
            return
        }
        do {
            let bridge = try PreviewBridge(transport: transport, remotePort: candidate)
            self.bridge = bridge
            Task {
                do {
                    localPort = try await bridge.start()
                } catch {
                    self.error = "\(error)"
                }
            }
        } catch {
            self.error = "\(error)"
        }
    }

    private func reload() async {
        bridge?.stop()
        bridge = nil
        localPort = nil
        port = nil
        error = nil
        await loadPorts()
    }

    private func loadPorts() async {
        loadingPorts = true
        defer { loadingPorts = false }
        for _ in 0..<40 {
            switch client.state {
            case .connected:
                board = try? await client.ports()
                return
            case .failed(let message):
                error = message
                return
            default:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        error = "Timed out connecting to the host."
    }

    /// What to call a listener: its framework if we know one, else its command,
    /// else nothing rather than a bare "dev" that every port would get.
    static func describe(_ listener: PortBoard.Listener) -> String? {
        if let framework = listener.framework, !framework.isEmpty { return framework }
        guard let command = listener.command, !command.isEmpty else { return nil }
        // The last path component, so `/usr/bin/node` reads `node`.
        let name = (command as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static let commonPorts: Set<Int> = [3000, 5173, 4200, 8000, 8080]
}

/// A `WKWebView` that loads the bridged loopback URL.
private struct WebView: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        if let url { webView.load(URLRequest(url: url)) }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only (re)load when the requested URL actually changes, otherwise
        // SwiftUI updates would fight the page's own navigation.
        guard let url else { return }
        if webView.url != url, !webView.isLoading {
            webView.load(URLRequest(url: url))
        }
    }
}