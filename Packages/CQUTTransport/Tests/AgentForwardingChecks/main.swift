import Foundation
import NIOCore
import Crypto
import CQUTTransport

// Proof that the forwarded agent actually forwards.
//
// The unit checks in SSHAgentChecks prove the protocol messages are built
// correctly. They cannot prove the interesting half: that a real sshd, after
// receiving `auth-agent-req@openssh.com`, opens the agent channel back to us,
// that our handler answers it, and that a program running *on the host* — not
// in this process — can then authenticate somewhere using the key it was given.
//
// So the test is deliberately indirect. It opens a session, and inside that
// session asks the host's sshd to open a *second* connection to itself,
// supplying a signature produced by whatever agent it can find. That nested
// connection can only succeed if the agent channel round-trip worked. A test
// that merely checked "did the request not error" would pass even if the agent
// channel were never served, which is exactly the failure mode worth ruling
// out — sshd agrees to the request and then finds nobody home.
//
// Above all it proves signing crosses the process boundary: the private key
// exists only in this process, and the host proves it can be used by a
// different process without ever holding it.

var failures = 0

/// Runs the main run loop for a while instead of sleeping.
///
/// Not a nicety: the transport delivers events with `DispatchQueue.main.async`,
/// and this is a command-line tool whose main thread would otherwise sit in
/// `Thread.sleep` and never service that queue. The app has a run loop running
/// the whole time, so a test that blocks the main thread tests something the
/// app never does — and reports "the session never came up" for a session that
/// came up fine.
func pump(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

func expect(_ pass: Bool, _ note: String, detail: String = "") {
    if !pass { failures += 1 }
    print("\(pass ? "PASS" : "FAIL")  \(note)")
    if !pass && !detail.isEmpty { print("        \(detail)") }
}

// MARK: - Arguments

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: agent-checks <host> <port> <seed-hex-or-file>\n".utf8))
    exit(2)
}
let host = args[1]
let port = Int(args[2]) ?? 2222
let seedPath = args[3]

guard let seed = try? Data(contentsOf: URL(fileURLWithPath: seedPath)) else {
    FileHandle.standardError.write(Data("cannot read seed at \(seedPath)\n".utf8))
    exit(2)
}
// The seed file is 32 raw bytes written as text, because raw bytes do not
// survive a shell round trip. Hex and base64 are both accepted: `ssh-keygen`
// and the harness speak base64, so requiring hex would mean a conversion step
// whose only purpose is to satisfy this line, and a conversion step is where a
// wrong-key failure would hide.
let seedText = String(decoding: seed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
let seedBytes = Data(hexString: seedText) ?? Data(base64Encoded: seedText)
guard let seedBytes, seedBytes.count == 32 else {
    FileHandle.standardError.write(Data("seed must be 32 bytes as hex or base64\n".utf8))
    exit(2)
}

let credential = SSHCredential.ed25519Seed(seedBytes)
guard let identity = credential.agentIdentity else {
    FileHandle.standardError.write(Data("could not derive the public key\n".utf8))
    exit(2)
}
print("— forwarding \(identity.publicKeyOpenSSH.split(separator: " ").prefix(2).joined(separator: " ")) —\n")

guard let keyBlob = SSHAgent.wireBlob(publicKeyOpenSSH: identity.publicKeyOpenSSH) else {
    FileHandle.standardError.write(Data("could not build the key blob\n".utf8))
    exit(2)
}

// MARK: - The session

let configuration = TransportConfiguration(
    host: host,
    port: port,
    username: NSUserName(),
    credential: credential,
    forwardAgent: true,
    agentSigner: SSHCredential.agentSigner(for: credential)
)

let transport = SSHTransport()
let transcript = Transcript()
transport.onEvent = { event in
    switch event {
    case .output(let data): transcript.append(data)
    case .connected: transcript.mark("connected")
    case .failed(let message): transcript.append(Data("\n[transport failed: \(message)]\n".utf8))
    case .closed(let code): transcript.mark("closed(\(code.map(String.init) ?? "-"))")
    }
}

transport.connect(configuration, cols: 80, rows: 24)
expect(transcript.wait(for: "connected", timeout: 20), "the session came up")

// MARK: - Ask the host to use the agent

// The nested ssh is the whole test. `-o IdentityAgent=none` is not needed and
// must not be set: sshd sets SSH_AUTH_SOCK inside the session itself, and this
// command must use exactly what the server provided rather than anything this
// test arranges.
//
// `BatchMode=yes` keeps a failure fast rather than hanging on a password
// prompt. `StrictHostKeyChecking=no` because the host key is the ephemeral one
// the harness generated a moment ago.
let nested = """
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
-p \(port) \(NSUserName())@\(host) \
'echo AGENT_NESTED_OK; echo SSH_AUTH_SOCK=$SSH_AUTH_SOCK; ssh-add -l'
"""

for line in ["ssh-add -l", nested, "echo AGENT_DONE"] {
    transport.send(Data((line + "\n").utf8))
    pump(1.5)
}
pump(10)

let text = transcript.text

// MARK: - Assertions

// Everything the top-level session printed, up to the point it was asked to
// open the nested connection. The split matters: the nested shell has no agent
// of its own — it never asked for one — so its `ssh-add -l` failing is correct
// behaviour, and an assertion that scanned the whole transcript would read that
// as the feature being broken.
let topLevel = text.components(separatedBy: "ssh -o BatchMode=yes").first ?? text

// 1. The host reached an agent at all. Without the request, sshd leaves
//    SSH_AUTH_SOCK unset and `ssh-add -l` says "Could not open a connection to
//    your authentication agent" — which is exactly what this session printed
//    before the request was moved ahead of the shell request.
expect(
    !topLevel.contains("Could not open a connection to your authentication agent"),
    "the host reached a forwarded agent"
)

// 2. The key in it is this connection's key. Not the comment, and not the
//    base64 body: `ssh-add -l` prints a SHA256 fingerprint, and the fingerprint
//    is the one thing a wrong key cannot share. Checking the comment alone
//    would pass for any key we happened to label "cqutmux".
let fingerprint = Data(SHA256.hash(data: keyBlob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
expect(topLevel.contains(fingerprint), "the forwarded key is this connection's key", detail: "SHA256:\(fingerprint)")

// 3. Exactly one identity was offered. Moshi documents forwarding exactly one,
//    and a second key here would mean something other than this connection's
//    credential was exported.
let listed = topLevel.split(separator: "\n").filter { $0.contains("SHA256:") && $0.contains("(ED25519)") }
expect(listed.count == 1, "only this connection's key was offered", detail: "saw \(listed.count) key lines")

// 4. The nested connection authenticated with it. This is the assertion that
//    matters, and the one a request-only implementation fails: the host had to
//    obtain a signature from our process to complete a second SSH handshake.
//    `ssh-add -l` listing a key only proves the channel was served; a signature
//    produced and accepted proves the private key is reachable across the
//    process boundary, which is the whole feature.
expect(text.contains("AGENT_NESTED_OK"), "the host authenticated again using the forwarded key")

// 5. It is genuinely a second session, not an echo of the first.
expect(!text.contains("Permission denied"), "no authentication failure in the session")

transport.disconnect()

// On failure, the transcript *is* the diagnosis: a check that talks to a live
// server fails for reasons that live on the server's side, and re-running it
// with a print statement added is a worse use of a minute than printing it once.
if failures > 0 {
    print("\n--- session transcript ---\n\(text)\n--- end ---\n")
}

print("\n\(failures == 0 ? "agent forwarding check passed" : "agent forwarding check FAILED (\(failures))")")
exit(failures == 0 ? 0 : 1)

// MARK: - Helpers

/// Collects session output and lets the test wait for a marker.
final class Transcript: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    func mark(_ text: String) {
        append(Data("\n<<\(text)>>\n".utf8))
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func wait(for marker: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if text.contains("<<\(marker)>>") { return true }
            pump(0.25)
        }
        return false
    }
}

extension Data {
    init?(hexString: String) {
        let cleaned = hexString.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}