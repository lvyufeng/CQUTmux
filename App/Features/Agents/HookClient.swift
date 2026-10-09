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

    /// Fired after every merge, so a mirror (the watch) can be kept current
    /// without polling the client. Delivered on the main queue.
    var onEventsChanged: (@Sendable ([AgentEvent]) -> Void)?

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

    /// The live SSH transport, so a preview bridge can open extra tunnels
    /// through the same session. Only valid while `state == .connected`.
    func forwardTransport() -> SSHTransport? {
        state == .connected ? transport : nil
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

    /// The gateway's `/health`, as the Support screen shows it.
    ///
    /// Kept here rather than assembled in the view because the request has to go
    /// over the same tunnel the rest of the client uses, with the same bearer
    /// token — a `URLSession` call from the view would reach the phone's own
    /// loopback, where there is no gateway at all.
    func health() async throws -> Health {
        let payload = try await request("GET", "/health")
        guard payload.status == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Health.self, from: payload.body)
    }

    /// What `/health` reports. Every field is optional: this is a diagnostic,
    /// and a gateway a version ahead of the app must still be reportable rather
    /// than failing to decode at the one moment someone is trying to find out
    /// what is wrong.
    struct Health: Decodable {
        var ok: Bool?
        var events: Int?
        var pendingApprovals: Int?
        var uptime: Int?
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
        let snapshot = events
        DispatchQueue.main.async { [weak self] in self?.onEventsChanged?(snapshot) }
    }

    /// Hands the host's gateway this device's APNs token, so the host can push
    /// an approval the moment it appears instead of waiting for the next poll.
    /// A failure is not fatal — polling still carries the same events — so it
    /// is recorded rather than thrown.
    func registerPushToken(_ token: String) async {
        let body = Data("{\"token\":\"\(token)\"}".utf8)
        _ = try? await request("POST", "/push/register", body: body)
    }

    /// Pulls the next page immediately instead of waiting out the poll
    /// interval, for when a push has just told us something changed.
    func refreshNow() {
        Task { [weak self] in
            guard let self, let payload = try? await self.request("GET", "/events?since=\(self.lastId)"),
                  let page = try? JSONDecoder().decode(AgentEventPage.self, from: payload.body)
            else { return }
            if !page.events.isEmpty { self.merge(page.events) }
            self.lastId = page.lastId
        }
    }

    func resolve(_ event: AgentEvent, allow: Bool) {
        send(decision: allow ? "allow" : "deny", answer: nil, for: event)
    }

    /// Answers a question by choosing one of its options. The decision is
    /// recorded as "allow" so a consumer that knows nothing about options
    /// still reads the question as answered rather than left hanging.
    func resolve(_ event: AgentEvent, answer: String) {
        send(decision: "allow", answer: answer, for: event)
    }

    private func send(decision: String, answer: String?, for event: AgentEvent) {
        Task { [weak self] in
            guard let self else { return }
            // Encoded, not interpolated: an option value is agent-supplied text
            // and one containing a quote or a backslash would otherwise produce
            // a body the gateway cannot parse — which fails as "the answer did
            // nothing", with nothing to see.
            struct Body: Encodable { let decision: String; let answer: String? }
            guard let body = try? JSONEncoder().encode(Body(decision: decision, answer: answer)) else { return }
            guard let payload = try? await self.request("POST", "/approve/\(event.id)", body: body) else { return }
            // The gateway answers with the *mutated* record, and this used to
            // throw it away. That left the local copy pending forever: the poll
            // asks for `id > lastId`, so an event the client already holds is
            // never re-sent, and an approval answered on the phone stayed in
            // "Needs you" until the app was relaunched. The one screen a user
            // acts on was the one that did not reflect their action.
            if let updated = try? JSONDecoder().decode(AgentEvent.self, from: payload.body) {
                self.merge([updated])
            }
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

    /// The diff for one file inside a directory.
    ///
    /// Narrowed on the host rather than filtered here: opening one file from a
    /// list of forty would otherwise re-send the whole working tree's diff to
    /// show a hunk the phone already has.
    func gitDiff(path: String, file: String) async throws -> DiffResult {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let encodedFile = file.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? file
        let payload = try await request("GET", "/diff?path=\(encodedPath)&file=\(encodedFile)")
        return try JSONDecoder().decode(DiffResult.self, from: payload.body)
    }

    func gitLog(path: String, limit: Int = 40) async throws -> LogResult {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let payload = try await request("GET", "/log?path=\(encoded)&limit=\(limit)")
        return try JSONDecoder().decode(LogResult.self, from: payload.body)
    }

    /// The agent's session log, read as a conversation. `path` is the project
/// directory, the same one the Files and Changes tabs browse.
    func transcript(path: String, limit: Int = 200) async throws -> AgentTranscript {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let payload = try await request("GET", "/transcript?path=\(encoded)&limit=\(limit)")
        return try JSONDecoder().decode(AgentTranscript.self, from: payload.body)
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

    /// Herdr's own tree: workspaces, tabs and the panes inside them. Separate
    /// from `/sessions` because it is a deeper shape than a session list —
    /// what it is for is jumping to a pane, which tmux and zellij cannot
    /// address by name at all.
    func herdrTree() async throws -> HerdrTree {
        let payload = try await request("GET", "/herdr")
        return try JSONDecoder().decode(HerdrTree.self, from: payload.body)
    }

    /// Focuses a pane by id. Goes through the socket API on the host, since
    /// `herdr pane focus` on the command line is directional only.
    func focusHerdrPane(_ paneId: String) async throws {
        let encoded = paneId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? paneId
        _ = try await request("POST", "/herdr/focus/\(encoded)")
    }

    /// Full-screens herdr's focused pane, or restores the layout.
    ///
    /// Through the tunnel like everything else: the gateway runs on the host,
    /// and the phone's own loopback has nothing listening on that port.
    func zoomHerdrPane(zoomed: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["zoomed": zoomed])
        _ = try await request("POST", "/herdr/zoom", body: body)
    }

    // MARK: - Dev-server ports

    func ports() async throws -> PortBoard {
        let payload = try await request("GET", "/ports")
        return try JSONDecoder().decode(PortBoard.self, from: payload.body)
    }

    // MARK: - Recent directories

    /// The directories the agents on the host have recently worked in.
    ///
    /// Discovered on the host rather than recorded here: the paths worth coming
    /// back to are the ones an agent ran in, and those were opened from the
    /// host's own terminal, not from this app's browser.
    func recentDirectories() async throws -> RecentDirectoryBoard {
        let payload = try await request("GET", "/recent-directories")
        return try JSONDecoder().decode(RecentDirectoryBoard.self, from: payload.body)
    }

    // MARK: - Command history

    /// The commands recently run on the host, newest first.
    ///
    /// Not gated on `always_on_discovery` the way recent directories are: the
    /// history file is read to answer a question the user asked by pressing the
    /// key, whereas discovery scans the disk on a timer whether or not anyone
    /// is looking.
    func commandHistory(limit: Int = 200) async throws -> CommandHistoryBoard {
        let payload = try await request("GET", "/history?limit=\(limit)")
        return try JSONDecoder().decode(CommandHistoryBoard.self, from: payload.body)
    }

    // MARK: - Simulator preview

    func simulators() async throws -> SimulatorBoard {
        let payload = try await request("GET", "/simulators")
        return try JSONDecoder().decode(SimulatorBoard.self, from: payload.body)
    }

    /// A PNG screenshot of a booted simulator on the host.
    func simulatorScreenshot(udid: String) async throws -> Data {
        let encoded = udid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? udid
        let payload = try await request("GET", "/simulator/screenshot?udid=\(encoded)", timeout: 25)
        return payload.body
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

    /// What has already been pasted, newest first.
    ///
    /// The paste directory is write-only without this: a screenshot the user
    /// needs again has to be uploaded again, which is what the list exists to
    /// avoid.
    func uploads() async throws -> [UploadBoard.Upload] {
        let payload = try await request("GET", "/uploads")
        return try JSONDecoder().decode(UploadBoard.self, from: payload.body).uploads
    }

    func uploadData(name: String) async throws -> Data {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let payload = try await request("GET", "/upload?name=\(encoded)", timeout: 60)
        return payload.body
    }

    func deleteUpload(name: String) async throws {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        _ = try await request("DELETE", "/upload?name=\(encoded)")
    }
}

struct UploadResult: Codable {
    var path: String
    var bytes: Int
    /// Whether the host put the path on its own clipboard. Present from the
    /// gateway; `nil` against an older one, which is not an error.
    var clipboard: ClipboardResult?

    struct ClipboardResult: Codable {
        var copied: Bool
        var tool: String?
        var reason: String?
    }
}

struct UploadBoard: Codable {
    struct Upload: Codable, Identifiable, Hashable {
        var name: String
        var path: String
        var bytes: Int
        /// ISO-8601, matching how `LogResult.Commit` carries its date.
        var at: String

        var id: String { name }
        var date: Date? { ISODate.parse(at) }

        /// Whether a thumbnail is worth asking the host for.
        var isImage: Bool {
            let lowered = name.lowercased()
            return [".png", ".jpg", ".jpeg", ".heic", ".gif", ".webp"]
                .contains { lowered.hasSuffix($0) }
        }

        var sizeLabel: String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    var root: String
    var uploads: [Upload]
}

struct PortBoard: Codable {
    var available: Bool
    var error: String?
    var ports: [Int]
}

/// Directories the host's agents have been working in, discovered from their
/// own on-disk history.
///
/// `enabled` is the `always-on-discovery` flag: false means the host was asked
/// not to go looking, which is different from having looked and found nothing,
/// and the screen says so rather than showing an empty list.
struct RecentDirectoryBoard: Codable {
    struct Entry: Codable, Identifiable {
        var path: String
        /// Milliseconds since the epoch, from the newest transcript in that
        /// directory — when the agent was last active there.
        var at: Double
        /// Which agent's history this came from.
        var agent: String
        /// True when the path was reconstructed from a project's directory name
        /// rather than read from a record. The name is lossy — a dash inside a
        /// directory is indistinguishable from a separator — so a guess is
        /// shown as a guess.
        var inferred: Bool

        var id: String { path }

        var folderName: String {
            (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
        }

        /// The directory above the folder, for a second line that tells two
        /// same-named checkouts apart.
        var parentPath: String {
            let parent = (path as NSString).deletingLastPathComponent
            return parent.isEmpty ? "/" : parent
        }

        var agentLabel: String {
            switch agent {
            case "claude": "Claude Code"
            case "codex": "Codex"
            case "cursor": "Cursor"
            case "opencode": "OpenCode"
            default: agent
            }
        }

        var agentSymbol: String {
            switch agent {
            case "claude": "sparkle"
            case "codex": "chevron.left.forwardslash.chevron.right"
            case "cursor": "cursorarrow"
            case "opencode": "terminal"
            default: "terminal"
            }
        }
    }

    var enabled: Bool = true
    var available: Bool = true
    var error: String?
    var directories: [Entry] = []
}

/// The commands recently run on the host, read from the shell's own history
/// file. Typing a long command on a phone keyboard is the thing this exists to
/// avoid, so the list is only useful if it is the *real* history — see
/// `host/cqutmux-hook/history.mjs` for the parsing rules.
struct CommandHistoryBoard: Codable {
    struct Entry: Codable, Identifiable {
        var command: String
        /// Milliseconds since the epoch, or `null` for a plain-format record,
        /// which carries no time. A missing time is not an error.
        var at: Double?
        /// Which shell's history file it came from.
        var shell: String

        // The command is the identity: the host deduplicates by it, so two
        // rows with the same text would be the same row.
        var id: String { command }

        /// The first line, for a row label that does not collapse into a
        /// multi-line blur. The rest is shown in the detail row.
        var firstLine: String { command.split(separator: "\n").first.map(String.init) ?? command }

        var isMultiline: Bool { command.contains("\n") }

        /// The remaining lines, joined for a secondary label. Empty when the
        /// command is a single line.
        var continuation: String {
            let lines = command.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.dropFirst().joined(separator: " ⏎ ")
        }

        var hasTime: Bool { at != nil }
    }

    var available: Bool = true
    var error: String?
    var commands: [Entry] = []
}

struct SimulatorBoard: Codable {
    struct Simulator: Codable, Identifiable {
        var udid: String
        var name: String
        var runtime: String
        var id: String { udid }
    }
    var available: Bool
    var error: String?
    var simulators: [Simulator]
}

struct SessionBoard: Codable {
    struct Window: Codable, Identifiable {
        /// What the owning mux takes to reach this window when jumping to it:
        /// a numeric index for tmux and zellij, a tab id (`w1:t2`) for herdr.
        /// Kept as a string so neither mux has to be forced into the other's
        /// addressing scheme.
        var selector: String
        var name: String
        var active: Bool
        var panes: Int
        var id: String { selector }

        /// What to show for this window. A numeric selector is the index the
        /// user types after the tmux prefix, so it is worth showing; herdr's
        /// is an opaque tab id (`w1:t2`) and would only be noise.
        var label: String {
            selector.allSatisfy(\.isNumber) ? "\(selector): \(name)" : name
        }
    }

    struct Session: Codable, Identifiable {
        /// Which multiplexer owns the session: "tmux", "zellij" or "herdr".
        var mux: String
        var name: String
        var windows: Int
        var attached: Bool
        var createdAt: String?
        var windowList: [Window]
        /// Herdr's own view of the agent in the workspace — `working`,
        /// `blocked`, `idle`, `done`. Absent for tmux and zellij, which have
        /// no such notion.
        var status: String?
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

/// Herdr's session tree, as the host flattens it: workspaces contain tabs,
/// tabs contain panes, and an agent's status rides on the pane it runs in.
struct HerdrTree: Codable {
    struct Workspace: Codable, Identifiable {
        var id: String
        var label: String
        var focused: Bool
        var paneCount: Int
        var tabCount: Int
        var status: String
    }

    struct Pane: Codable, Identifiable {
        var paneId: String
        /// Optional because the host reports panes twice: nested under their
        /// tab, where a label is worked out, and in the flat `agents` list,
        /// where herdr's raw record has none.
        var label: String?
        var tab: String
        var workspace: String
        var agent: String
        var status: String
        var cwd: String
        var focused: Bool
        var id: String { paneId }

        var displayLabel: String { label ?? paneId }
    }

    struct Tab: Codable, Identifiable {
        var id: String
        var label: String
        var workspace: String
        var focused: Bool
        var panes: [Pane]
    }

    var installed: Bool
    var version: String?
    var focusedPaneId: String?
    var workspaces: [Workspace]
    var tabs: [Tab]
    var agents: [Pane]

    /// Tabs under the workspace they belong to, in herdr's own order.
    func tabs(in workspace: Workspace) -> [Tab] {
        tabs.filter { $0.workspace == workspace.label }
    }
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
    struct File: Codable, Identifiable, Hashable {
        var status: String
        var path: String
        var id: String { path }

        /// The last path component, which is what a reviewer scans for.
        var name: String { (path as NSString).lastPathComponent }
        /// Everything before it, so two files of the same name in different
        /// directories are told apart without reading the whole path.
        var directory: String {
            let parent = (path as NSString).deletingLastPathComponent
            return parent == path ? "" : parent
        }
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

        var dateValue: Date? { ISODate.parse(date) }
    }
    var isRepo: Bool
    var commits: [Commit]
}