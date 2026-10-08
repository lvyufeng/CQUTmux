import Foundation

/// Everything needed to open one interactive session with a host.
public struct TransportConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var credential: SSHCredential
    public var terminalType: String
    public var environment: [String: String]

    public init(
        host: String,
        port: Int = 22,
        username: String,
        credential: SSHCredential,
        terminalType: String = "xterm-256color",
        environment: [String: String] = ["LANG": "en_US.UTF-8"]
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
        self.terminalType = terminalType
        self.environment = environment
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
}