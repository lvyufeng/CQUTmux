import SwiftUI
import CQUTTransport

/// Bridges `CQUTTerminalView` into SwiftUI and hosts the keyboard accessory bar.
struct TerminalScreen: View {
    let host: Host
    let credential: SSHCredential

    @State private var coordinator = TerminalCoordinator()
    @State private var dictation = VoiceDictation()
    @State private var showSessions = false
    @Environment(ThemeStore.self) private var themes
    @Environment(AgentConnection.self) private var connection

    var body: some View {
        TerminalViewRepresentable(host: host, credential: credential, coordinator: coordinator, theme: themes.current)
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(host.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { StatusBadge(status: coordinator.status) }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        coordinator.terminal?.reconnect()
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showSessions) { sessionPicker }
            .safeAreaInset(edge: .bottom, spacing: 0) { accessoryBar }
            .onAppear {
                // Partial transcripts stream straight to the shell; a final
                // one gets a newline so the agent receives the command.
                dictation.onUpdate = { update in
                    switch update {
                    case .partial(let text): coordinator.setDictationPreview(text)
                    case .final(let text):
                        coordinator.setDictationPreview("")
                        coordinator.terminal?.sendDictatedLine(text)
                    }
                }
                #if DEBUG
                if ProcessInfo.processInfo.environment["CQUT_DEV_SHEET"] == "sessions" {
                    showSessions = true
                }
                #endif
            }
    }

    private var accessoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("Ctrl", CtrlKey.control)
                key("Esc", CtrlKey.escape)
                key("Tab", CtrlKey.tab)
                icon("arrow.up", CtrlKey.upArrow)
                icon("arrow.down", CtrlKey.downArrow)
                icon("arrow.left", CtrlKey.leftArrow)
                icon("arrow.right", CtrlKey.rightArrow)
                icon("doc.on.doc", CtrlKey.clipboard)
                sessionsButton
                dictationButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .overlay(alignment: .top) {
            if !coordinator.dictationPreview.isEmpty {
                Text(coordinator.dictationPreview)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .offset(y: -22)
                    .transition(.opacity)
            }
        }
    }

    /// tmux sessions live behind the host gateway, so the picker needs the
    /// shared agent connection. It is hidden when no host is connected.
    @ViewBuilder
    private var sessionsButton: some View {
        if connection.client != nil {
            Button { showSessions = true } label: {
                Image(systemName: "rectangle.stack").frame(width: 40, height: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 6))
        }
    }

    @ViewBuilder
    private var sessionPicker: some View {
        if let client = connection.client {
            SessionPickerView(client: client) { action in
                switch action {
                case .attach(let name):
                    coordinator.terminal?.attachSession(name)
                case .window(_, let index):
                    coordinator.terminal?.selectWindow(index: index)
                }
            }
        }
    }

    private var dictationButton: some View {
        Button {
            dictation.toggle()
        } label: {
            Image(systemName: dictation.isListening ? "waveform" : "mic")
                .symbolEffect(.variableColor, isActive: dictation.isListening)
                .frame(width: 40, height: 32)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 6))
        .tint(dictation.isListening ? Theme.accent : nil)
    }

    private func key(_ label: String, _ key: CtrlKey) -> some View {
        Button { coordinator.press(key) } label: {
            Text(label)
                .font(.system(.subheadline, design: .monospaced))
                .frame(minWidth: 44, minHeight: 32)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 6))
    }

    private func icon(_ systemName: String, _ key: CtrlKey) -> some View {
        Button { coordinator.press(key) } label: {
            Image(systemName: systemName)
                .frame(width: 40, height: 32)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 6))
    }
}

enum CtrlKey {
    case control, escape, tab, upArrow, downArrow, leftArrow, rightArrow, clipboard
}

/// Owns the UIKit terminal and the SSH session across SwiftUI updates.
@Observable
final class TerminalCoordinator {
    var status: CQUTTerminalView.Status = .idle
    /// Live dictation text, shown above the accessory bar while listening.
    var dictationPreview = ""
    @ObservationIgnored weak var terminal: CQUTTerminalView?

    func setDictationPreview(_ text: String) { dictationPreview = text }

    func press(_ key: CtrlKey) {
        guard let terminal else { return }
        switch key {
        case .control: terminal.toggleControl()
        case .escape: terminal.sendEscape()
        case .tab: terminal.sendTab()
        case .upArrow: terminal.sendArrow(up: true, down: false, left: false, right: false)
        case .downArrow: terminal.sendArrow(up: false, down: true, left: false, right: false)
        case .rightArrow: terminal.sendArrow(up: false, down: false, left: false, right: true)
        case .leftArrow: terminal.sendArrow(up: false, down: false, left: true, right: false)
        case .clipboard: terminal.pasteFromClipboard()
        }
    }
}

private struct TerminalViewRepresentable: UIViewRepresentable {
    let host: Host
    let credential: SSHCredential
    let coordinator: TerminalCoordinator
    let theme: TerminalTheme

    func makeUIView(context: Context) -> CQUTTerminalView {
        let configuration = TransportConfiguration(
            host: host.hostname,
            port: host.port,
            username: host.username,
            credential: credential
        )
        let view = CQUTTerminalView(
            frame: .zero,
            configuration: configuration,
            startupCommand: host.sessionCommand.isEmpty ? nil : host.sessionCommand,
            theme: theme
        )
        view.onStatus = { status in coordinator.status = status }
        coordinator.terminal = view
        DispatchQueue.main.async { view.connect() }
        return view
    }

    func updateUIView(_ uiView: CQUTTerminalView, context: Context) {}
}

private struct StatusBadge: View {
    let status: CQUTTerminalView.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch status {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .closed: .orange
        case .idle: .gray
        }
    }

    private var text: String {
        switch status {
        case .idle: "idle"
        case .connecting: "connecting"
        case .connected: "connected"
        case .closed(let code): code.map { "closed (\($0))" } ?? "closed"
        case .failed: "failed"
        }
    }
}