import SwiftTerm
import CQUTTransport
import UIKit

/// A `TerminalView` wired to a `TerminalTransport`. Owns the transport for the
/// lifetime of one session and translates delegate callbacks into I/O.
///
/// `TerminalView` is a UIKit view; the transport pings `onEvent` on the main
/// queue, so every callback below already runs on the main thread.
final class CQUTTerminalView: TerminalView, TerminalViewDelegate {
    enum Status: Equatable {
        case idle, connecting, connected
        case closed(Int?)
        case failed(String)

        var isLive: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    var onStatus: ((Status) -> Void)?

    private let transport: TerminalTransport
    private let configuration: TransportConfiguration
    private let startupCommand: String?
    private let theme: TerminalTheme
    private var didRunStartup = false
    /// Font size that pinch zoom scales from, captured when a pinch begins.
    private var baseFontSize: CGFloat = 12

    /// Whether a dropped session should climb back on its own. This is the
    /// roaming story: the phone loses Wi-Fi or sleeps, and the terminal
    /// reattaches to the persistent tmux/zellij session rather than making the
    /// user notice. Mosh does this at the transport layer; over SSH we do it
    /// with backoff plus a foreground nudge.
    var autoReconnect = true
    private var retryTask: Task<Void, Never>?
    private var attempt = 0
    /// Set while the user asks to disconnect, so teardown isn't "a drop".
    private var userInitiated = false
    private var status: Status = .idle {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    init(
        frame: CGRect,
        configuration: TransportConfiguration,
        startupCommand: String?,
        theme: TerminalTheme = TerminalTheme.named(nil),
        transport: TerminalTransport = SSHTransport()
    ) {
        self.configuration = configuration
        self.startupCommand = startupCommand
        self.theme = theme
        self.transport = transport
        super.init(frame: frame)

        terminalDelegate = self
        font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        baseFontSize = font.pointSize
        theme.apply(to: self)
        installGestures()

        transport.onEvent = { [weak self] event in
            self?.handle(event)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        retryTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        transport.disconnect()
    }

    // MARK: - Gestures

    private lazy var pinch: UIPinchGestureRecognizer = {
        let gesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        return gesture
    }()

    private func installGestures() {
        addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        // A three-finger horizontal swipe switches tmux windows, matching
        // Moshi's terminal gestures. The window index keys are Ctrl-b then
        // 0-9; a swipe left/right walks them.
        for (direction, delta) in [(UISwipeGestureRecognizer.Direction.left, 1), (.right, -1)] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 3
            swipe.accessibilityValue = String(delta)
            addGestureRecognizer(swipe)
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed else {
            if gesture.state == .ended { baseFontSize = font.pointSize }
            return
        }
        let size = max(7, min(28, baseFontSize * gesture.scale))
        font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        sendTab()
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard let delta = Int(gesture.accessibilityValue ?? "0") else { return }
        // Ctrl-b n / Ctrl-b p — next/previous tmux window.
        write(Data([0x02]))
        write(Data(delta > 0 ? [0x6E] : [0x70]))
    }

    // MARK: - Session control

    func connect() {
        guard case .idle = status else { return }
        userInitiated = false
        status = .connecting
        let terminal = getTerminal()
        transport.connect(configuration, cols: max(terminal.cols, 80), rows: max(terminal.rows, 24))
        _ = becomeFirstResponder()
    }

    /// Manual retry from the toolbar: clears any pending backoff and starts
    /// immediately.
    func reconnect() {
        retryTask?.cancel()
        retryTask = nil
        transport.disconnect()
        didRunStartup = false
        attempt = 0
        status = .idle
        connect()
    }

    func disconnect() {
        userInitiated = true
        retryTask?.cancel()
        retryTask = nil
        transport.disconnect()
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .connected:
            status = .connected
            attempt = 0
            if let startupCommand, !didRunStartup {
                didRunStartup = true
                write(Data((startupCommand + "\n").utf8))
            }
        case .output(let data):
            feed(byteArray: ArraySlice(data))
        case .closed(let code):
            status = .closed(code)
            scheduleReconnect(reason: "connection closed")
        case .failed(let message):
            status = .failed(message)
            feed(text: "\r\n\u{1b}[31m[connection failed] \(message)\u{1b}[0m\r\n")
            scheduleReconnect(reason: message)
        }
    }

    // MARK: - Reconnection

    /// Exponential backoff capped at 30s. The first retries come fast so a
    /// brief Wi-Fi blip is a blink; later ones slow down so a genuinely gone
    /// host doesn't hammer the radio.
    private func scheduleReconnect(reason: String) {
        guard autoReconnect, !userInitiated else { return }
        retryTask?.cancel()
        let delay = min(30, pow(2, Double(attempt)))
        attempt += 1
        retryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.feed(text: "\r\n\u{1b}[33m[reconnecting · attempt \(self.attempt)]\u{1b}[0m\r\n")
            self.didRunStartup = false
            self.status = .idle
            self.connect()
        }
    }

    /// Coming back to the foreground after a suspend is the common case where
    /// the SSH socket has already been torn down, so kick a retry right away
    /// instead of waiting for the backoff timer.
    @objc private func appDidBecomeActive() {
        guard autoReconnect, !userInitiated else { return }
        switch status {
        case .connected, .connecting:
            return
        case .closed, .failed, .idle:
            attempt = 0
            scheduleReconnect(reason: "foreground")
        }
    }

    // MARK: - Key injection (used by the accessory bar)

    /// Ctrl is a sticky modifier SwiftTerm already understands: toggling it
    /// turns the next key the user types into its control character.
    func toggleControl() { controlModifier.toggle() }

    func sendEscape() { write(Data([0x1B])) }

    func sendTab() { write(Data([0x09])) }

    func sendArrow(up: Bool, down: Bool, left: Bool, right: Bool) {
        let final: Character = up ? "A" : down ? "B" : right ? "C" : "D"
        write(Data("\u{1B}[\(final)".utf8))
    }

    func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string else { return }
        write(Data(text.utf8))
    }

    /// Sends a dictated phrase followed by Return, so the shell runs it.
    func sendDictatedLine(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        write(Data((trimmed + "\n").utf8))
    }

    /// Types text into the session without a trailing newline, so the user can
    /// finish (or edit) the line before submitting. Used after an image paste
    /// to drop the uploaded path into the agent's prompt.
    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        write(Data(text.utf8))
    }

    /// Switches to a session on whichever multiplexer owns it. tmux prefers
    /// `switch-client` when we are already inside a client and `attach`
    /// otherwise; zellij re-attaches by name.
    func attachSession(mux: String, name: String) {
        let quoted = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch mux {
        case "zellij":
            write(Data("zellij attach \(quoted)\n".utf8))
        default:
            write(Data("tmux switch-client -t \(quoted) 2>/dev/null || tmux attach -t \(quoted)\n".utf8))
        }
    }

    /// Jumps to a window/tab in the attached client. tmux jumps by sending the
    /// prefix key — so the command is interpreted by tmux rather than typed
    /// into a pane that may be busy running an agent — falling back to the
    /// command prompt past index 9. zellij has no prefix port; it gets a
    /// `go-to-tab` action instead.
    func selectWindow(mux: String, session: String, index: Int) {
        switch mux {
        case "zellij":
            write(Data("zellij -s \(session) action go-to-tab \(index + 1)\n".utf8))
        default:
            write(Data([0x02])) // Ctrl-b
            if (0...9).contains(index) {
                write(Data(String(index).utf8))
            } else {
                write(Data(":select-window -t \(index)\n".utf8))
            }
        }
    }

    private func write(_ data: Data) {
        transport.send(data)
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        transport.send(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        transport.resize(cols: newCols, rows: newRows)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func bell(source: TerminalView) {}

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }
}