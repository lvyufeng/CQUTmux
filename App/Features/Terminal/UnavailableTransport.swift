import Foundation
import CQUTTransport

/// A connection kind this build cannot provide, and the reason to show.
struct TransportUnavailable: Error {
    let reason: String
}

/// A transport that cannot connect, and says why.
///
/// Used for the connection kinds this build does not implement (ET). Failing
/// loudly is the point: a user who picks ET and gets an SSH session has been
/// lied to about which protocol is protecting their session.
final class UnavailableTransport: TerminalTransport {
    var onEvent: (@Sendable (TransportEvent) -> Void)?

    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func connect(_ configuration: TransportConfiguration, cols: Int, rows: Int) {
        onEvent?(.failed(reason))
    }

    func send(_ data: Data) {}
    func resize(cols: Int, rows: Int) {}
    func disconnect() {}
}