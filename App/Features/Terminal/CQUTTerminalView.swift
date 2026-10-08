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
    }

    var onStatus: ((Status) -> Void)?

    private let transport: TerminalTransport
    private let configuration: TransportConfiguration
    private let startupCommand: String?
    private let theme: TerminalTheme
    private var didRunStartup = false
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
        theme.apply(to: self)

        transport.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { transport.disconnect() }

    // MARK: - Session control

    func connect() {
        guard case .idle = status else { return }
        status = .connecting
        let terminal = getTerminal()
        transport.connect(configuration, cols: max(terminal.cols, 80), rows: max(terminal.rows, 24))
        _ = becomeFirstResponder()
    }

    func reconnect() {
        transport.disconnect()
        didRunStartup = false
        status = .idle
        connect()
    }

    func disconnect() {
        transport.disconnect()
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .connected:
            status = .connected
            if let startupCommand, !didRunStartup {
                didRunStartup = true
                write(Data((startupCommand + "\n").utf8))
            }
        case .output(let data):
            feed(byteArray: ArraySlice(data))
        case .closed(let code):
            status = .closed(code)
        case .failed(let message):
            status = .failed(message)
            feed(text: "\r\n\u{1b}[31m[connection failed] \(message)\u{1b}[0m\r\n")
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