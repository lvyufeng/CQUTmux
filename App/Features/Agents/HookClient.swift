import Foundation
import Observation
import CQUTTransport

/// Talks to the host's `cqutmux-hook` gateway through the SSH connection.
/// The gateway is loopback-only on the host; every request rides the SSH
/// channel via `direct-tcpip`, so nothing is exposed to the network.
@Observable
final class HookClient {
    enum State: Equatable {
        case idle, connecting, connected
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var events: [AgentEvent] = []
    private(set) var lastError: String?

    private let transport = SSHTransport()
    private let configuration: TransportConfiguration
    private let remotePort: Int
    /// Bearer token for a host gateway started with `--token`; nil when the
    /// gateway is unauthenticated.
    private let token: String?
    private var socket: ForwardedSocket?
    private var lastId = 0
    private var polling = false

    init(configuration: TransportConfiguration, remotePort: Int = 24543, token: String? = nil) {
        self.configuration = configuration
        self.remotePort = remotePort
        self.token = token
    }

    var pendingCount: Int { events.filter(\.isPending).count }

    func start() {
        guard state == .idle else { return }
        state = .connecting

        transport.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected:
                self.openTunnel()
            case .failed(let message):
                self.state = .failed(message)
            case .closed:
                self.state = .idle
            case .output:
                break // the shell channel is only here to hold the SSH session
            }
        }

        let terminal = (cols: 80, rows: 24)
        transport.connect(configuration, cols: terminal.cols, rows: terminal.rows)
    }

    func stop() {
        polling = false
        socket?.close()
        socket = nil
        transport.disconnect()
        state = .idle
    }

    private func openTunnel() {
        var carry = Data()
        socket = transport.forward(
            remoteHost: "127.0.0.1",
            remotePort: remotePort,
            onData: { [weak self] chunk in
                carry.append(chunk)
                self?.consume(&carry)
            },
            onClose: { [weak self] in
                self?.state = .failed("gateway closed the connection")
            }
        )
        state = .connected
        pollLoop()
    }

    // MARK: - Minimal HTTP/1.1 client over the forwarded channel

    private var pendingResponse: CheckedContinuation<HTTPPayload, Error>?
    private var carry = Data()
    /// Only one request may be in flight: a single socket and a single pending
    /// continuation can't disambiguate interleaved responses. Without this the
    /// event poll and a file fetch issued together deadlock.
    private let gate = SerialGate()

    private struct HTTPPayload {
        var status: Int
        var body: Data
    }

    private func consume(_ buffer: inout Data) {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        let headerText = String(decoding: headerData, as: UTF8.self)
        let status = Int(headerText.split(separator: " ").dropFirst().first ?? "0") ?? 0
        let contentLength = headerText
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return }

        let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: contentLength))
        buffer.removeSubrange(buffer.startIndex..<buffer.index(bodyStart, offsetBy: contentLength))

        let continuation = pendingResponse
        pendingResponse = nil
        continuation?.resume(returning: HTTPPayload(status: status, body: body))
    }

    private func request(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        headers: [String: String] = [:],
        timeout: TimeInterval = 30
    ) async throws -> HTTPPayload {
        await gate.acquire()
        defer { gate.release() }
        guard socket != nil else { throw URLError(.notConnectedToInternet) }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n"
        if let token { head += "authorization: Bearer \(token)\r\n" }
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        // Binary uploads carry their own type; everything else is JSON.
        if let body {
            head += headers.keys.contains(where: { $0.lowercased() == "content-type" })
                ? "content-length: \(body.count)\r\n"
                : "content-type: application/json\r\ncontent-length: \(body.count)\r\n"
        }
        head += "\r\n"
        var raw = Data(head.utf8)
        if let body { raw.append(body) }

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponse = continuation
            socket?.send(raw)
        }
    }

    // MARK: - Polling

    private func pollLoop() {
        guard !polling else { return }
        polling = true
        Task { [weak self] in
            guard let self else { return }
            while self.polling {
                do {
                    let payload = try await self.request("GET", "/events?since=\(self.lastId)")
                    let page = try JSONDecoder().decode(AgentEventPage.self, from: payload.body)
                    if !page.events.isEmpty {
                        self.merge(page.events)
                    }
                    self.lastId = page.lastId
                    self.lastError = nil
                } catch {
                    self.lastError = "\(error)"
                    try? await Task.sleep(for: .seconds(2))
                }
                // Pace the short poll so the connection isn't saturated.
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private func merge(_ incoming: [AgentEvent]) {
        var byId = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        for event in incoming { byId[event.id] = event }
        events = byId.values.sorted { $0.id > $1.id }
    }

    func resolve(_ event: AgentEvent, allow: Bool) {
        Task { [weak self] in
            guard let self else { return }
            let body = Data("{\"decision\":\"\(allow ? "allow" : "deny")\"}".utf8)
            _ = try? await self.request("POST", "/approve/\(event.id)", body: body)
        }
    }

    // MARK: - Files and diffs

    func listFiles(path: String) async throws -> DirectoryListing {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let payload = try await request("GET", "/files?path=\(encoded)")
        return try JSONDecoder().decode(DirectoryListing.self, from: payload.body)
    }

    func readFile(path: String) async throws -> FileContents {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let payload = try await request("GET", "/file?path=\(encoded)")
        return try JSONDecoder().decode(FileContents.self, from: payload.body)
    }

    func gitDiff(path: String) async throws -> DiffResult {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let payload = try await request("GET", "/diff?path=\(encoded)")
        return try JSONDecoder().decode(DiffResult.self, from: payload.body)
    }

    func gitLog(path: String, limit: Int = 40) async throws -> LogResult {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let payload = try await request("GET", "/log?path=\(encoded)&limit=\(limit)")
        return try JSONDecoder().decode(LogResult.self, from: payload.body)
    }

    func usage() async throws -> UsageBoard {
        let payload = try await request("GET", "/usage")
        return try JSONDecoder().decode(UsageBoard.self, from: payload.body)
    }

    // MARK: - tmux sessions

    func sessions() async throws -> SessionBoard {
        let payload = try await request("GET", "/sessions")
        return try JSONDecoder().decode(SessionBoard.self, from: payload.body)
    }

    // MARK: - Uploads

    /// Uploads a pasted image to the host and returns the path it was written
    /// to, which the caller types into the agent's prompt.
    func uploadImage(_ data: Data, filename: String, contentType: String = "image/png") async throws -> UploadResult {
        let payload = try await request(
            "POST", "/upload", body: data,
            headers: ["x-filename": filename, "content-type": contentType]
        )
        return try JSONDecoder().decode(UploadResult.self, from: payload.body)
    }
}

struct UploadResult: Codable {
    var path: String
    var bytes: Int
}

struct SessionBoard: Codable {
    struct Window: Codable, Identifiable {
        var index: Int
        var name: String
        var active: Bool
        var panes: Int
        var id: Int { index }
    }

    struct Session: Codable, Identifiable {
        /// Which multiplexer owns the session: "tmux" or "zellij".
        var mux: String
        var name: String
        var windows: Int
        var attached: Bool
        var createdAt: String?
        var windowList: [Window]
        var id: String { "\(mux):\(name)" }
    }

    var available: Bool
    var error: String?
    var sessions: [Session]
}

struct UsageBoard: Codable {
    var generatedAt: String?
    var entries: [UsageEntry]
}

struct UsageEntry: Codable, Identifiable {
    var source: String
    var label: String
    var pace: String?
    var windows: [UsageWindow]
    var id: String { source }
}

struct UsageWindow: Codable, Identifiable {
    var label: String
    var percent: Double
    var resetIn: String?
    var id: String { label }
}

struct DirectoryListing: Codable {
    struct Entry: Codable, Identifiable {
        var name: String
        var dir: Bool
        var id: String { name }
    }
    var root: String
    var path: String
    var entries: [Entry]
}

struct FileContents: Codable {
    var path: String
    var size: Int
    var content: String
}

struct DiffResult: Codable {
    struct File: Codable, Identifiable {
        var status: String
        var path: String
        var id: String { path }
    }
    var isRepo: Bool
    var files: [File]
    var diff: String
}

struct LogResult: Codable {
    struct Commit: Codable, Identifiable {
        var hash: String
        var short: String
        var author: String
        var date: String
        var subject: String
        var refs: String
        var id: String { hash }

        var dateValue: Date? { ISO8601DateFormatter().date(from: date) }
    }
    var isRepo: Bool
    var commits: [Commit]
}