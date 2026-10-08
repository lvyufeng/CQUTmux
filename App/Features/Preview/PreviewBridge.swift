import Foundation
import Network
import CQUTTransport

/// Bridges a loopback TCP port on the device to a port on the host, over the
/// SSH connection.
///
/// The point is to keep the web view HTTP-unaware: `WKWebView` loads
/// `http://127.0.0.1:<localPort>` and speaks plain HTTP, while this class
/// shuttles those bytes through `direct-tcpip` channels to the host's dev
/// server. Nothing is exposed to the network at either end — the local socket
/// is loopback-only and the remote leg never leaves the SSH session.
final class PreviewBridge {
    enum BridgeError: Error { case alreadyRunning, noTransport }

    /// The loopback port the web view should load. Assigned by the system.
    private(set) var localPort: Int = 0

    private let queue = DispatchQueue(label: "app.cqutmux.preview")
    private let listener: NWListener
    private unowned let transport: SSHTransport
    private let remoteHost: String
    private let remotePort: Int
    /// Live forwarded sockets, keyed by connection, so we can tear them down.
    private var sockets: [ObjectIdentifier: ForwardedSocket] = [:]
    /// The device-side connections. Held strongly: nothing else retains them
    /// once `newConnectionHandler` returns, and letting one deallocate would
    /// orphan its forwarded socket and silently drop the response.
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(transport: SSHTransport, remoteHost: String = "127.0.0.1", remotePort: Int) throws {
        self.transport = transport
        self.remoteHost = remoteHost
        self.remotePort = remotePort

        // Bind loopback only, on any free port.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: .any
        )
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns once a port has been assigned.
    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port?.rawValue else { return }
                    self.localPort = Int(port)
                    if !resumed { resumed = true; continuation.resume(returning: Int(port)) }
                case .failed(let error):
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            for socket in self.sockets.values { socket.close() }
            for connection in self.connections.values { connection.cancel() }
            self.sockets.removeAll()
            self.connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.start(queue: queue)

        // Open the far leg first; the browser's bytes buffer inside the
        // ForwardedSocket until the channel attaches.
        guard let socket = transport.forward(
            remoteHost: remoteHost,
            remotePort: remotePort,
            onData: { connection.send(content: $0, completion: .contentProcessed { _ in }) },
            onClose: { connection.cancel() }
        ) else {
            close(key, connection)
            return
        }
        sockets[key] = socket
        pump(connection, key: key, into: socket)
    }

    /// Moves browser → host. Runs until the connection ends.
    private func pump(_ connection: NWConnection, key: ObjectIdentifier, into socket: ForwardedSocket) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty { socket.send(data) }
            if isComplete || error != nil {
                socket.close()
                self?.queue.async { self?.close(key, connection) }
                return
            }
            self?.pump(connection, key: key, into: socket)
        }
    }

    private func close(_ key: ObjectIdentifier, _ connection: NWConnection) {
        sockets[key] = nil
        connections[key] = nil
        connection.cancel()
    }
}