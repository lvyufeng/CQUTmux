import Foundation

/// A jump host the session is tunnelled through: the SSH connection to the
/// target is carried inside a `direct-tcpip` channel on this one.
public struct JumpHost: Sendable {
    public var host: String
    public var port: Int
    /// Credentials for the jump. Defaults to the target's when the UI only
    /// collects `user@host:port`, which is the common case of one account
    /// hop-through.
    public var username: String
    public var credential: SSHCredential

    public init(host: String, port: Int = 22, username: String, credential: SSHCredential) {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
    }

    /// Parses `host`, `host:port`, `user@host` or `user@host:port`. A bare
    /// host with no user inherits `fallbackUser`. Returns nil for an empty
    /// string so callers can treat "no jump host" and "blank field" alike.
    public static func parse(
        _ text: String?,
        fallbackUser: String,
        credential: SSHCredential
    ) -> JumpHost? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let (userPart, hostPart) = {
            let pieces = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            return pieces.count == 2
                ? (String(pieces[0]), String(pieces[1]))
                : ("", trimmed)
        }()

        // Port is behind the last colon, but only when what follows is numeric
        // — a bare IPv6 literal has colons and no port, and we shouldn't eat it.
        var host = hostPart
        var port = 22
        if let colon = hostPart.lastIndex(of: ":") {
            let tail = String(hostPart[hostPart.index(after: colon)...])
            if let parsedPort = Int(tail), !tail.isEmpty {
                host = String(hostPart[..<colon])
                port = parsedPort
            }
        }
        guard !host.isEmpty else { return nil }

        return JumpHost(
            host: host,
            port: port,
            username: userPart.isEmpty ? fallbackUser : userPart,
            credential: credential
        )
    }
}

/// Everything needed to open one interactive session with a host.
public struct TransportConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var credential: SSHCredential
    public var terminalType: String
    public var environment: [String: String]
    /// When set, the connection to `host:port` rides a `direct-tcpip` channel
    /// on this host rather than opening a socket of its own.
    public var jumpHost: JumpHost?

    public init(
        host: String,
        port: Int = 22,
        username: String,
        credential: SSHCredential,
        terminalType: String = "xterm-256color",
        environment: [String: String] = ["LANG": "en_US.UTF-8"],
        jumpHost: JumpHost? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
        self.terminalType = terminalType
        self.environment = environment
        self.jumpHost = jumpHost
    }
}

/// Signals produced by a live transport. Delivered on the main queue.
public enum TransportEvent: Sendable {
    case connected
    case output(Data)
    case closed(Int?)
    case failed(String)
}

/// A byte-stream session against a host. SSH is the first implementation;
/// Mosh and ET plug in behind the same surface (PLAN.md §2).
public protocol TerminalTransport: AnyObject {
    /// Called on the main queue for every event.
    var onEvent: (@Sendable (TransportEvent) -> Void)? { get set }

    func connect(_ configuration: TransportConfiguration, cols: Int, rows: Int)
    func send(_ data: Data)
    func resize(cols: Int, rows: Int)
    func disconnect()

    /// Whether a dropped session is recovered by the transport itself.
    ///
    /// Mosh is a state-sync protocol: it keeps the screen on both ends and
    /// resumes from the next datagram, so a caller that also retries would be
    /// tearing down a session that was never actually lost. SSH has no such
    /// layer, so the caller supplies the backoff.
    var handlesReconnect: Bool { get }
}

extension TerminalTransport {
    public var handlesReconnect: Bool { false }
}