import SwiftUI
import CQUTTransport

/// Bridges `CQUTTerminalView` into SwiftUI and hosts the keyboard accessory bar.
struct TerminalScreen: View {
    let host: Host
    let credential: SSHCredential

    @State private var coordinator = TerminalCoordinator()

    var body: some View {
        TerminalViewRepresentable(host: host, credential: credential, coordinator: coordinator)
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
            .safeAreaInset(edge: .bottom, spacing: 0) { accessoryBar }
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
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.bar)
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
    @ObservationIgnored weak var terminal: CQUTTerminalView?

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
            startupCommand: host.sessionCommand.isEmpty ? nil : host.sessionCommand
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