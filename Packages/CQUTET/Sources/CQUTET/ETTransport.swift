import Foundation
import CQUTETC
import CQUTTransport

#if canImport(Darwin)
import Darwin
#endif

/// A `TerminalTransport` backed by Eternal Terminal's own client core.
///
/// ET exists for the networks mosh cannot reach. Mosh needs UDP and a port that
/// nothing has to open; ET speaks TCP on one port (2022 by default) through the
/// same kind of SSH session the app already has, and its own reconnect logic
/// reattaches to the server-side session after the link drops. So the two
/// transports are complements: mosh for roaming and sleep, ET for a network
/// that blocks UDP.
///
/// Unlike mosh, the run loop here is *not* ours. ET's `TerminalClient::run()`
/// is a blocking loop that owns its own thread, so the driver starts it on one
/// and this type only drains what it produces. There is no fd to poll for
/// output — `et_socket_fd` is a hint that goes stale the moment ET reconnects,
/// which is the one thing it is guaranteed to do — so the drain is on a timer.
/// That is cheap: `et_recv` returns without copying anything when the buffer is
/// empty.
public final class ETTransport: TerminalTransport {
    public var onEvent: (@Sendable (TransportEvent) -> Void)?

    /// ET reconnects on its own, and that is the reason to prefer it on a
    /// hostile network: the session lives on the server and the client
    /// reattaches to it. The caller must not tear it down to retry — that would
    /// throw away the thing that makes ET worth having.
    ///
    /// The exception is before a session exists at all. A host with no
    /// `etterminal`, or a bootstrap that failed, has nothing to preserve.
    public var handlesReconnect: Bool { queue.sync { started } }

    /// How the host's `etterminal` gets started. ET is not client-only: the
    /// host runs a daemon, and the client must be started with the credentials
    /// it was given. Without a launcher there is no session.
    public var launcher: ETLauncher?

    private var driver: OpaquePointer?
    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "app.cqutmux.transport.et")
    private var started = false

    public init() {}

    public func connect(_ configuration: TransportConfiguration, cols: Int, rows: Int) {
        guard let launcher else {
            emit(.failed("Eternal Terminal needs a host session to start etterminal"))
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let endpoint = try await launcher.startETSession(cols: cols, rows: rows)
                let driver = endpoint.id.withCString { id in
                    endpoint.passkey.withCString { passkey in
                        endpoint.host.withCString { host in
                            et_start(id, passkey, host, Int32(endpoint.port),
                                     Int32(cols), Int32(rows))
                        }
                    }
                }
                guard let driver else {
                    self.emit(.failed("ET could not start a session (bad credentials or unreachable server)"))
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
        emit(.connected)

        // ET says nothing until the socket is carrying data, and nothing tells
        // us when that happens: `et_still_connecting` is a poll, not a signal.
        // So this drains on a fixed cadence and reports readiness once.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(25))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
    }

    /// Drains whatever ET's loop has produced, and notices when it gives up.
    ///
    /// The `handlesReconnect` contract would be a lie if a dead session looked
    /// like a quiet one, so the driver's `et_connection_lost` is checked here
    /// and surfaced as a failure — which is what lets the caller fall back to
    /// SSH instead of showing a frozen terminal.
    private func poll() {
        // This runs on `queue` — it is the timer's handler — so it must not
        // use queue.sync to reach its own state. Doing so re-enters the serial
        // queue from inside it, which libdispatch detects and traps.
        guard let driver, started else { return }

        // One read covers however much ET batched. The loop is bounded because
        // a very chatty session should not starve the timer that notices the
        // connection dying.
        var progressed = false
        for _ in 0..<64 {
            guard let chunk = et_recv(driver) else { break }
            let data = Data(bytes: chunk, count: strlen(chunk))
            et_free(chunk)
            if !data.isEmpty {
                progressed = true
                emit(.output(data))
            }
        }

        // A quiet session and a dead one look the same from here, so ask. The
        // session has already ended by the time this is true; the point is to
        // say so rather than leave a frozen terminal on screen.
        if !progressed, et_connection_lost(driver) != 0 {
            started = false
            emit(.failed("ET session ended: the connection could not be recovered"))
        }
    }

    public func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, let driver = self.driver, !data.isEmpty else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return }
                et_push_keys(driver, base, data.count)
            }
        }
    }

    public func resize(cols: Int, rows: Int) {
        queue.async { [weak self] in
            guard let self, let driver = self.driver else { return }
            et_push_resize(driver, Int32(cols), Int32(rows))
        }
    }

    public func disconnect() {
        let (driver, timer): (OpaquePointer?, DispatchSourceTimer?) = queue.sync {
            let snapshot = (self.driver, self.pollTimer)
            self.driver = nil
            self.pollTimer = nil
            self.started = false
            return snapshot
        }
        timer?.cancel()

        guard let driver else { return }
        // et_stop shuts the client down and joins its thread, so this does not
        // return until ET's loop has actually finished.
        et_stop(driver)
        launcher?.stop()
    }

    private func emit(_ event: TransportEvent) {
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }
}

/// The credentials and address a live `etterminal` reported.
///
/// ET's server mints its own id/passkey and prints them as
/// `IDPASSKEY:<id>/<passkey>`; the client must connect with exactly those, so
/// this is read back from the bootstrap rather than generated locally.
public struct ETEndpoint: Sendable {
    public var id: String
    public var passkey: String
    public var host: String
    public var port: Int
}

public enum ETLaunchError: Error, CustomStringConvertible {
    case notInstalled
    case badBanner(String)

    public var description: String {
        switch self {
        case .notInstalled:
            "etterminal is not installed on the host (ET needs it; ssh alone is not enough)"
        case .badBanner(let text):
            "could not read ET's credentials from: \(text)"
        }
    }
}

/// Starts `etterminal` on the host, which in turn starts `etserver` if one is
/// not already listening.
///
/// This is the same handover mosh needs, with a different banner: mosh prints
/// `MOSH CONNECT <port> <key>`, ET prints `IDPASSKEY:<id>/<passkey>`. Both are
/// run over the SSH session the app already has, which is why the transport
/// takes a launcher rather than owning a connection of its own.
public protocol ETLauncher: AnyObject, Sendable {
    func startETSession(cols: Int, rows: Int) async throws -> ETEndpoint
    /// Releases the session used to start the server. ET, unlike mosh, keeps
    /// its TCP connection for the life of the terminal, so this is only about
    /// the bootstrap.
    func stop()
}

public extension ETLauncher {
    func stop() {}
}

extension ETEndpoint {
    /// Parses the `IDPASSKEY:<id>/<passkey>` line from `etterminal`'s output.
    ///
    /// The line comes back through a pty, so it carries a CR — and a passkey
    /// with a CR on the end is one byte longer than the crypto expects, which
    /// shows up as a generic connect timeout rather than as anything to do with
    /// parsing. Trimming it here is why this is a function and not a split.
    public static func parse(banner: String) throws -> ETEndpoint? {
        for line in banner.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("IDPASSKEY:") else { continue }
            let pair = text.dropFirst("IDPASSKEY:".count)
            guard let slash = pair.firstIndex(of: "/") else { continue }
            let id = String(pair[pair.startIndex..<slash])
            let passkey = String(pair[pair.index(after: slash)...])
            guard !id.isEmpty, !passkey.isEmpty else { continue }
            return ETEndpoint(id: id, passkey: passkey, host: "127.0.0.1", port: 2022)
        }
        return nil
    }
}