import Foundation
import Observation
import CQUTTransport

/// App-level connection to one host's agent gateway, shared by the Inbox and
/// Code tabs so a single SSH session serves both.
@Observable
final class AgentConnection {
    private(set) var client: HookClient?
    private(set) var host: Host?
    private(set) var lastError: String?

    func connect(to host: Host) {
        client?.stop()
        self.host = host
        lastError = nil

        let credential: SSHCredential
        if let seed = KeychainStore.load(account: host.keySeedAccount) {
            credential = .ed25519Seed(seed)
        } else if let data = KeychainStore.load(account: host.passwordAccount),
                  let text = String(data: data, encoding: .utf8) {
            credential = .password(text)
        } else {
            lastError = "No saved credentials for \(host.displayName). Connect once from the Terminal tab."
            client = nil
            return
        }

        let configuration = TransportConfiguration(
            host: host.hostname, port: host.port, username: host.username, credential: credential
        )
        let client = HookClient(configuration: configuration)
        self.client = client
        client.start()
    }
}