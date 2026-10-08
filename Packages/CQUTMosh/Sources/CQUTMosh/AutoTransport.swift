import Foundation
import CQUTTransport

/// Tries `primary` and falls back to `fallback` when the primary cannot be
/// used at all.
///
/// Both halves are pluggable, but the pairing this exists for is mosh then ET:
/// Moshi's own order. The interesting case is mosh-server missing from the host
/// — not a network failure, and one that retrying will not fix — so the session
/// has to continue some other way. ET then covers the other half of that: it
/// needs only TCP and an etterminal, so it works on the networks where mosh's
/// UDP never arrives.
///
/// The names in the messages are taken from the transports themselves rather
/// than hardcoded, because a hardcoded "falling back to SSH" was wrong the
/// moment ET was inserted ahead of SSH, and a message that misreports which
/// transport is carrying the session is worse than no message.
///
/// Failures *after* the session is up are deliberately not caught: once the
/// primary is talking, a drop is a drop, and both mosh and ET recover from one
/// better than a restart-as-something-else would. Only a failure before the
/// first frame means the transport never worked.
public final class AutoTransport: TerminalTransport, @unchecked Sendable {
    public var onEvent: (@Sendable (TransportEvent) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    /// After a switch the fallback decides for itself; before one, so does the
    /// primary. Both mosh and ET recover on their own, and SSH says it does
    /// not, so this is a property of whichever is live rather than of the
    /// wrapper.
    public var handlesReconnect: Bool { lock.withLock { switched } ? fallback.handlesReconnect : primary.handlesReconnect }

    private var _onEvent: (@Sendable (TransportEvent) -> Void)?
    private let primary: TerminalTransport
    private let fallback: TerminalTransport
    private let lock = NSLock()

    /// What to call each side in the message the user sees. A `TerminalTransport`
    /// has no name of its own — adding one to the protocol for a log line would
    /// be a poor trade — so the factory that chose them passes them in.
    private let primaryName: String
    private let fallbackName: String

    private var active: TerminalTransport?
    /// Set once the fallback has taken over, so a late failure from the primary
    /// (its socket teardown, say) is not attributed to the live session.
    private var switched = false
    private var configuration: TransportConfiguration?
    private var size: (cols: Int, rows: Int) = (80, 24)

    public init(
        primary: TerminalTransport,
        fallback: TerminalTransport,
        primaryName: String = "mosh",
        fallbackName: String = "SSH"
    ) {
        self.primary = primary
        self.fallback = fallback
        self.primaryName = primaryName
        self.fallbackName = fallbackName
    }

    public func connect(_ configuration: TransportConfiguration, cols: Int, rows: Int) {
        lock.withLock {
            self.configuration = configuration
            self.size = (cols, rows)
            self.switched = false
            self.active = primary
        }
        primary.onEvent = { [weak self] event in self?.route(event, from: self?.primary) }
        primary.connect(configuration, cols: cols, rows: rows)
    }

    public func send(_ data: Data) {
        lock.withLock { active }?.send(data)
    }

    public func resize(cols: Int, rows: Int) {
        lock.withLock {
            size = (cols, rows)
            return active
        }?.resize(cols: cols, rows: rows)
    }

    public func disconnect() {
        let (a, b) = lock.withLock { (active, switched ? nil : primary) }
        a?.disconnect()
        // If the primary is still the one that never worked, tear it down too:
        // it may be holding an SSH session it used to start mosh-server.
        if let b, b !== a { b.disconnect() }
    }

    private func route(_ event: TransportEvent, from source: TerminalTransport?) {
        let handler = onEvent

        guard !lock.withLock({ switched }) else {
            // The fallback owns the session now. Only the fallback's output is
            // meaningful; anything the primary says at this point is noise.
            if source === lock.withLock({ active }) { handler?(event) }
            return
        }

        switch event {
        case .failed(let message) where source === primary:
            handler?(.output(Data("\r\n\u{1b}[33m[\(primaryName) unavailable — falling back to \(fallbackName): \(message)]\u{1b}[0m\r\n".utf8)))
            switchToFallback()
        case .connected:
            lock.withLock { active = source }
            handler?(event)
        default:
            handler?(event)
        }
    }

    private func switchToFallback() {
        let (configuration, size) = lock.withLock {
            switched = true
            active = fallback
            return (self.configuration, self.size)
        }
        guard let configuration else { return }
        primary.disconnect()
        fallback.onEvent = { [weak self] event in
            self?.onEvent?(event)
        }
        fallback.connect(configuration, cols: size.cols, rows: size.rows)
    }
}