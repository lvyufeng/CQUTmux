import Foundation
import CQUTTransport

/// Tries `primary` (mosh) and falls back to `fallback` (SSH) when the primary
/// cannot be used at all.
///
/// The interesting case is mosh-server missing from the host. That is not a
/// network failure and retrying it will not help, so the session has to
/// continue some other way — which is what Moshi's "Auto" does, and why the
/// first failure is the only one that switches.
///
/// Failures *after* the session is up are deliberately not caught: once mosh
/// is talking, a drop is a drop, and mosh is better at recovering from it than
/// a restart-as-SSH would be. Only a failure before the first frame means the
/// transport never worked.
public final class AutoTransport: TerminalTransport, @unchecked Sendable {
    public var onEvent: (@Sendable (TransportEvent) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    /// After a switch the fallback is SSH, which needs the caller's backoff;
    /// before one, mosh recovers by itself.
    public var handlesReconnect: Bool { lock.withLock { switched } ? fallback.handlesReconnect : primary.handlesReconnect }

    private var _onEvent: (@Sendable (TransportEvent) -> Void)?
    private let primary: TerminalTransport
    private let fallback: TerminalTransport
    private let lock = NSLock()

    private var active: TerminalTransport?
    /// Set once the fallback has taken over, so a late failure from the primary
    /// (its socket teardown, say) is not attributed to the live session.
    private var switched = false
    private var configuration: TransportConfiguration?
    private var size: (cols: Int, rows: Int) = (80, 24)

    public init(primary: TerminalTransport, fallback: TerminalTransport) {
        self.primary = primary
        self.fallback = fallback
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
            handler?(.output(Data("\r\n\u{1b}[33m[mosh unavailable — falling back to SSH: \(message)]\u{1b}[0m\r\n".utf8)))
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