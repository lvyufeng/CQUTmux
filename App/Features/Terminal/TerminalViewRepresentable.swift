import SwiftUI
import UIKit
import CQUTTransport

/// `sheet(item:)` needs an `Identifiable`; `UIImage` isn't one.
struct PendingImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Bridges `CQUTTerminalView` into SwiftUI and hosts the keyboard accessory bar.
struct TerminalScreen: View {
    let host: Host
    let credential: SSHCredential

    @State private var coordinator = TerminalCoordinator()
    @State private var dictation = VoiceDictation()
    @State private var showSessions = false
    @State private var annotating: PendingImage?
    @State private var pastedNotice: String?
    @Environment(ThemeStore.self) private var themes
    @Environment(TerminalFontStore.self) private var fonts
    @Environment(AgentConnection.self) private var connection

    var body: some View {
        TerminalViewRepresentable(
                host: host,
                credential: credential,
                coordinator: coordinator,
                theme: themes.current,
                fonts: fonts
            )
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
            .sheet(item: $annotating) { pending in annotator(pending.image) }
            .overlay(alignment: .top) { pasteNotice }
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
                if ProcessInfo.processInfo.environment["CQUT_DEV_SHEET"] == "annotate" {
                    // Wait a beat so the gateway tunnel is up; otherwise the
                    // sheet renders its connecting placeholder.
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        annotating = PendingImage(image: Self.debugFixture())
                    }
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
                pasteImageButton
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

    /// Image paste needs the gateway to carry the bytes to the host, so the
    /// button only appears when a host is connected.
    @ViewBuilder
    private var pasteImageButton: some View {
        if connection.client != nil {
            Button(action: pasteImage) {
                Image(systemName: "photo.badge.plus").frame(width: 40, height: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 6))
        }
    }

    private func pasteImage() {
        guard let image = UIPasteboard.general.image else {
            pastedNotice = "No image on the clipboard"
            Task {
                try? await Task.sleep(for: .seconds(2))
                pastedNotice = nil
            }
            return
        }
        annotating = PendingImage(image: image)
    }

    @ViewBuilder
    private func annotator(_ image: UIImage) -> some View {
        // The sheet can open before the tunnel finishes coming up; show a
        // placeholder rather than an empty sheet in that window.
        if let client = connection.client {
            ImageAnnotatorView(image: image, client: client) { path in
                // Drop the uploaded path into the prompt; the user finishes
                // the message and submits it themselves.
                coordinator.terminal?.typeText(path + " ")
                pastedNotice = "Sent to \(path)"
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    pastedNotice = nil
                }
            }
        } else {
            NavigationStack { ProgressView("Connecting…") }
        }
    }

    @ViewBuilder
    private var pasteNotice: some View {
        if let pastedNotice {
            Text(pastedNotice)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// A stand-in screenshot so a UI run can exercise the annotator without
    /// staging a real clipboard image. Debug builds only.
    private static func debugFixture() -> UIImage {
        let size = CGSize(width: 640, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor(white: 0.12, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = "246  func connect() {\n247      status = .connecting\n248      transport.connect(...)\n249  }"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular),
                .foregroundColor: UIColor(red: 0.6, green: 1, blue: 0.7, alpha: 1),
            ]
            (text as NSString).draw(at: CGPoint(x: 24, y: 40), withAttributes: attributes)
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
                case .attach(let mux, let name):
                    coordinator.terminal?.attachSession(mux: mux, name: name)
                case .window(let mux, let session, let index):
                    coordinator.terminal?.selectWindow(mux: mux, session: session, index: index)
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
    let fonts: TerminalFontStore

    func makeUIView(context: Context) -> CQUTTerminalView {
        let configuration = TransportConfiguration(
            host: host.hostname,
            port: host.port,
            username: host.username,
            credential: credential,
            // The jump host authenticates with the same credential the user
            // saved for the target; the form takes `user@host:port` but has no
            // separate secret, and a single account hop-through is the usual
            // shape. Parsing handles the bare-IPv6 case without eating it.
            jumpHost: JumpHost.parse(
                host.jumpHost,
                fallbackUser: host.username,
                credential: credential
            )
        )
        let view = CQUTTerminalView(
            frame: .zero,
            configuration: configuration,
            startupCommand: host.sessionCommand.isEmpty ? nil : host.sessionCommand,
            theme: theme,
            font: fonts.uiFont()
        )
        view.onStatus = { status in coordinator.status = status }
        // A pinch resizes the terminal and becomes the saved preference, so the
        // next session opens at the size the user settled on.
        view.onFontSizeChange = { size in
            fonts.size = Double(size)
        }
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