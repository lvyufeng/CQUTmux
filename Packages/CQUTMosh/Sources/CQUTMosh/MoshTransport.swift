import Foundation
import CQUTMoshC
import CQUTTransport

#if canImport(Darwin)
import Darwin
#endif

/// A `TerminalTransport` backed by mosh's own client libraries.
///
/// Mosh is a state-sync protocol, not a byte pipe: it keeps two copies of the
/// screen (here and on the server) and ships diffs, so a dropped or roaming
/// network resumes on the next datagram instead of restarting the session.
/// That is why this type looks so different from `SSHTransport` — it holds a
/// `Framebuffer`, not a byte stream, and hands the terminal finished frames.
///
/// The run loop is ours. Mosh's client libraries expose their UDP socket
/// rather than driving it, because iOS gives a UDP socket only to the process
/// that created it; a `DispatchSourceRead` on that fd is the bridge.
public final class MoshTransport: TerminalTransport {
    public var onEvent: (@Sendable (TransportEvent) -> Void)?

    /// Mosh resumes on its own: the session lives on the server and every
    /// datagram carries the state needed to rejoin it, so once it is running
    /// the caller must not tear it down to retry. Before that — a host with no
    /// mosh-server, an SSH session that would not open — there is nothing to
    /// preserve and a retry is the caller's to make.
    public var handlesReconnect: Bool { queue.sync { started } }

    /// Set by the app once it has a live SSH session, so `mosh-server` can be
    /// started on the host. Without it, mosh cannot be used: the server is a
    /// separate program that has to be launched remotely.
    public var launcher: MoshServerLauncher?

    private var driver: OpaquePointer?
    private var source: DispatchSourceRead?
    private var tickTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "app.cqutmux.transport.mosh")
    private var started = false
    private var cols = 80
    private var rows = 24

    public init() {}

    public func connect(_ configuration: TransportConfiguration, cols: Int, rows: Int) {
        guard let launcher else {
            emit(.failed("Mosh needs a host session to start mosh-server"))
            return
        }
        self.cols = cols
        self.rows = rows

        Task { [weak self] in
            guard let self else { return }
            do {
                let endpoint = try await launcher.startMoshServer(cols: cols, rows: rows)
                let driver = endpoint.key.withCString { key in
                    endpoint.host.withCString { host in
                        endpoint.port.withCString { port in
                            mosh_start(key, host, port, Int32(cols), Int32(rows))
                        }
                    }
                }
                guard let driver else {
                    self.emit(.failed("mosh could not start a session (bad key or unreachable server)"))
                    return
                }
                self.begin(driver)
            } catch {
                self.emit(.failed("\(error)"))
            }
        }
    }

    private func begin(_ driver: OpaquePointer) {
        queue.sync {
            self.driver = driver
            self.started = true
        }

        let fd = mosh_socket_fd(driver)
        guard fd >= 0 else {
            emit(.failed("mosh has no socket"))
            return
        }

        // The screen restore, emitted before mosh says anything, so the view
        // is in a known state even if the first update is a full repaint.
        if let initial = mosh_initial_frame(driver) {
            emit(.output(Data(bytes: initial, count: strlen(initial))))
            mosh_free(initial)
        }
        emit(.connected)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        self.source = source

        // Mosh wants to send on its own cadence (acks, pings) even when nothing
        // arrives, so a timer tick is part of the protocol, not an optimisation.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, let driver = self.driver else { return }
            mosh_tick(driver)
        }
        timer.resume()
        tickTimer = timer
    }

    /// Drains every datagram waiting on the socket. One read event can cover
    /// several, and mosh only advances per datagram.
    private func drain() {
        guard let driver else { return }
        // Bound the loop: a busy socket must not starve the timer.
        for _ in 0..<64 {
            guard let frame = mosh_recv(driver) else { break }
            let data = Data(bytes: frame, count: strlen(frame))
            mosh_free(frame)
            if !data.isEmpty {
                emit(.output(data))
            }
        }
    }

    public func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, let driver = self.driver, !data.isEmpty else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return }
                mosh_push_keys(driver, base, data.count)
            }
        }
    }

    public func resize(cols: Int, rows: Int) {
        queue.async { [weak self] in
            guard let self, let driver = self.driver else { return }
            self.cols = cols
            self.rows = rows
            mosh_push_resize(driver, Int32(cols), Int32(rows))
        }
    }

    public func disconnect() {
        let (driver, source, timer): (OpaquePointer?, DispatchSourceRead?, DispatchSourceTimer?) = queue.sync {
            let snapshot = (self.driver, self.source, self.tickTimer)
            self.driver = nil
            self.source = nil
            self.tickTimer = nil
            self.started = false
            return snapshot
        }
        source?.cancel()
        timer?.cancel()

        guard let driver else { return }
        // Best-effort courtesy to the server: it should not stay running for a
        // client that has gone. The session is detached, so a failure here is
        // not worth surfacing.
        if let restore = mosh_shutdown(driver) {
            emit(.output(Data(bytes: restore, count: strlen(restore))))
            mosh_free(restore)
        }
        mosh_stop(driver)
        // The SSH session that started the server has served its purpose; the
        // mosh session is running on its own. Leaving it open would keep a
        // connection alive for nothing (and, on a jump host, a second one).
        launcher?.stop()
    }

    private func emit(_ event: TransportEvent) {
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }
}

/// A `mosh-server` running on the host, as reported by its startup banner:
/// `MOSH CONNECT <port> <base64 key>`.
public struct MoshEndpoint: Sendable {
    public var host: String
    public var port: String
    public var key: String
}

public enum MoshLaunchError: Error, CustomStringConvertible {
    case serverNotInstalled
    case badBanner(String)

    public var description: String {
        switch self {
        case .serverNotInstalled:
            "mosh-server is not installed on the host (mosh needs it; ssh alone is not enough)"
        case .badBanner(let text):
            "could not read mosh-server's address from: \(text)"
        }
    }
}

/// Starts `mosh-server` on the host over the session that is already open.
///
/// Mosh is not a client-only protocol: the host runs `mosh-server`, which
/// opens a UDP port and prints a one-time key. The app therefore needs a way
/// to run a command on the host, which is exactly what the SSH transport
/// already provides — so this is a protocol, and `SSHTransport` supplies it.
public protocol MoshServerLauncher: AnyObject, Sendable {
    func startMoshServer(cols: Int, rows: Int) async throws -> MoshEndpoint
    /// Releases whatever was used to start the server — for an SSH launcher,
    /// the session that ran the command. Called when the terminal closes, so a
    /// background SSH connection outlives neither the session nor the app.
    func stop()
}

public extension MoshServerLauncher {
    func stop() {}
}

extension MoshEndpoint {
    /// Parses the `MOSH CONNECT <port> <key>` line from the server's output.
    public static func parse(banner: String) throws -> MoshEndpoint {
        for line in banner.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count >= 4, parts[0] == "MOSH", parts[1] == "CONNECT" {
                return MoshEndpoint(host: "127.0.0.1", port: String(parts[2]), key: String(parts[3]))
            }
        }
        throw MoshLaunchError.badBanner(banner)
    }
}