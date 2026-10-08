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
    /// Called when a pinch or a hardware change settles on a new size, so the
    /// user's font preference follows the gesture instead of being lost.
    var onFontSizeChange: ((CGFloat) -> Void)?

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
        font: UIFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        transport: TerminalTransport = SSHTransport()
    ) {
        self.configuration = configuration
        self.startupCommand = startupCommand
        self.theme = theme
        self.transport = transport
        super.init(frame: frame)

        terminalDelegate = self
        self.font = font
        baseFontSize = font.pointSize
        theme.apply(to: self)

        // Links are underlined and tappable without a modifier key. The default
        // is `.hover`, which on a touch screen means a link is only clickable
        // once a hover has already highlighted its whole row — reachable with a
        // trackpad and not with a finger. `AppleTerminalView` is explicit that
        // `.always` exists for this: it accepts implicit (regex-detected) links
        // outright, where the other modes require the row to be highlighted
        // first. `requestOpenLink` below does the opening, because on iOS
        // SwiftTerm hands the URL to the app rather than opening it — which is
        // also why nothing happens without that method.
        linkReporting = .implicit
        linkHighlightMode = .always

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
        switch gesture.state {
        case .changed:
            let size = min(
                max(CGFloat(TerminalFontStore.sizeRange.lowerBound), baseFontSize * gesture.scale),
                CGFloat(TerminalFontStore.sizeRange.upperBound)
            )
            font = font.withSize(size)
        case .ended, .cancelled, .failed:
            baseFontSize = font.pointSize
            onFontSizeChange?(font.pointSize)
        default:
            break
        }
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
        // A transport that recovers on its own (mosh) must not be torn down and
        // restarted: the stall it is recovering from would become a lost
        // session, which is exactly what mosh exists to avoid.
        guard !transport.handlesReconnect else { return }
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

    // MARK: - Hardware keyboard

    /// Shortcuts for a physical keyboard, matching the set Moshi documents.
    /// SwiftTerm has no hardware-key chrome of its own, so these are declared
    /// here and dispatched to the same helpers the accessory bar uses.
    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = [
            UIKeyCommand(input: "k", modifierFlags: .command, action: #selector(hardwareClear),
                         discoverabilityTitle: "Clear screen"),
            UIKeyCommand(input: "o", modifierFlags: .command, action: #selector(hardwareToggleControl),
                         discoverabilityTitle: "Toggle Ctrl"),
            UIKeyCommand(input: "r", modifierFlags: .command, action: #selector(hardwareReconnect),
                         discoverabilityTitle: "Reconnect"),
            UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(hardwarePaste),
                         discoverabilityTitle: "Paste"),
            UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(hardwarePrevWindow),
                         discoverabilityTitle: "Previous window"),
            UIKeyCommand(input: "]", modifierFlags: .command, action: #selector(hardwareNextWindow),
                         discoverabilityTitle: "Next window"),
        ]
        // ⌘1…⌘9 jump to a tmux window by index.
        for index in 1...9 {
            commands.append(
                UIKeyCommand(input: String(index), modifierFlags: .command,
                             action: #selector(hardwareWindow(_:)),
                             discoverabilityTitle: "Window \(index)")
            )
        }
        return (super.keyCommands ?? []) + commands
    }

    /// Ctrl-L clears the screen without touching the running program's state.
    @objc private func hardwareClear() { write(Data([0x0C])) }
    @objc private func hardwareToggleControl() { toggleControl() }
    @objc private func hardwareReconnect() { reconnect() }
    @objc private func hardwarePaste() { pasteFromClipboard() }

    @objc private func hardwarePrevWindow() {
        write(Data([0x02])); write(Data([0x70])) // Ctrl-b p
    }

    @objc private func hardwareNextWindow() {
        write(Data([0x02])); write(Data([0x6E])) // Ctrl-b n
    }

    @objc private func hardwareWindow(_ sender: UIKeyCommand) {
        guard let input = sender.input, let index = Int(input) else { return }
        selectWindow(mux: "tmux", session: "", selector: String(index))
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
    /// otherwise; zellij and herdr both re-attach by name.
    func attachSession(mux: String, name: String) {
        let quoted = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch mux {
        case "zellij":
            write(Data("zellij attach \(quoted)\n".utf8))
        case "herdr":
            // `herdr --session` launches or attaches to the named persistent
            // session; the bare form would attach to the default one and land
            // the user in the wrong place.
            write(Data("herdr --session \(quoted)\n".utf8))
        default:
            write(Data("tmux switch-client -t \(quoted) 2>/dev/null || tmux attach -t \(quoted)\n".utf8))
        }
    }

    /// Jumps to a window/tab in the attached client.
    ///
    /// `selector` is how the owning mux addresses the window, and it is not a
    /// number for every mux: tmux and zellij use an index, herdr addresses a
    /// tab by id (`w1:t2`). The picker passes back whatever it was given, so
    /// this never has to reconstruct an id from a position.
    ///
    /// tmux jumps by sending the prefix key — so the command is interpreted by
    /// tmux rather than typed into a pane that may be busy running an agent —
    /// falling back to the command prompt past index 9. zellij has no prefix
    /// port; it gets a `go-to-tab` action instead.
    func selectWindow(mux: String, session: String, selector: String) {
        switch mux {
        case "zellij":
            guard let index = Int(selector) else { return }
            write(Data("zellij -s \(session) action go-to-tab \(index + 1)\n".utf8))
        case "herdr":
            guard !selector.isEmpty else { return }
            write(Data("herdr tab focus \(selector)\n".utf8))
        default:
            guard let index = Int(selector) else { return }
            write(Data([0x02])) // Ctrl-b
            if (0...9).contains(index) {
                write(Data(String(index).utf8))
            } else {
                write(Data(":select-window -t \(index)\n".utf8))
            }
        }
    }

    /// Writes bytes the app composed itself rather than bytes the user typed —
    /// a custom shortcut, whose whole point is that the app already knows the
    /// exact sequence the terminal should receive.
    func sendRaw(_ data: Data) {
        guard !data.isEmpty else { return }
        write(data)
    }

    private func write(_ data: Data) {
        transport.send(data)
    }

    #if DEBUG
    /// Whether the session is up right now. Test-only.
    var isLiveForTesting: Bool { status.isLive }

    /// Types into the live session exactly as the keyboard does. Test-only;
    /// see `DebugSeed.typeWhenConnected`.
    func injectForTesting(_ text: String) {
        guard status.isLive else { return }
        write(Data(text.utf8))
    }
    #endif

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

    /// Opens a tapped link, but only if it is a web URL.
    ///
    /// The text on screen comes from whatever program is running on the far
    /// end, and SwiftTerm will hand over anything that looks like a link —
    /// including OSC 8 payloads, which the protocol allows to carry arbitrary
    /// key/value metadata rather than a URL. Passing that straight to
    /// `UIApplication.open` would let a remote program launch other apps on the
    /// phone through custom schemes; the tab's purpose here is to be read, so
    /// http and https are the whole of what opens.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        UIApplication.shared.open(url)
    }
}