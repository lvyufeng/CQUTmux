import Foundation
import CQUTTransport

// The agent protocol is small enough to get entirely wrong in ways a live
// server only reports as "permission denied", which is why these run without
// one. Every case here is a mistake that produces a plausible-looking message:
// a length prefix in the wrong place, the key blob in the text form instead of
// SSH's wire form, a signature wrapped where the agent protocol wants it raw,
// or a reply to a key we never offered.
//
// The signer is a stub, so the assertions can be exact rather than "some bytes
// came back".

var failures = 0

func expect(_ pass: Bool, _ note: String, got: String = "", want: String = "") {
    if !pass { failures += 1 }
    print("\(pass ? "PASS" : "FAIL")  \(note)")
    if !pass { print("        got \(got) wanted \(want)") }
}

func expect(_ got: Int, _ want: Int, _ note: String) {
    expect(got == want, note, got: "\(got)", want: "\(want)")
}

func expect(_ got: Data, _ want: Data, _ note: String) {
    expect(got == want, note, got: hex(got), want: hex(want))
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// Big-endian integer at `offset`, which is how every field in this protocol is
/// read — and reading them the same way the implementation writes them is the
/// point of the exercise.
func uint32(_ data: Data, _ offset: Int) -> Int {
    data[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
}

func slice(_ data: Data, _ offset: Int, _ count: Int) -> Data {
    Data(data[offset..<(offset + count)])
}

/// A single byte as an `Int`, so replies can be compared field by field without
/// every call site inventing a one-byte `Data`.
func byte(_ data: Data, _ index: Int) -> Int {
    Int(data[index])
}

// A real ed25519 key, so the blobs are the shapes a server actually sees.
let credential = SSHCredential.ed25519Seed(Data(repeating: 0x42, count: 32))
guard let identity = credential.agentIdentity else {
    print("FAIL  could not derive an identity from the seed")
    exit(1)
}
let publicKeyLine = identity.publicKeyOpenSSH
guard let keyBlob = SSHAgent.wireBlob(publicKeyOpenSSH: publicKeyLine) else {
    print("FAIL  could not build the key blob")
    exit(1)
}

// A signer returning a fixed value, so the coupling between the signature and
// the reply can be checked exactly.
let fixedSignature = Data(0..<64)
let agent = SSHAgent(identity: identity) { _, _ in fixedSignature }

// MARK: - The public key blob

print("— the key blob —")
// `ssh-ed25519 <base64>` decodes straight to the wire form: two length-prefixed
// strings, the algorithm name then the key bytes. Building it by hand and
// prefixing the algorithm again gives 70 bytes instead of 51 — a key that parses
// and is then rejected by authorized_keys for reasons the server never explains.
expect(keyBlob.count, 4 + 11 + 4 + 32, "blob is algorithm and key, each length-prefixed")

// A text form whose algorithm disagrees with the blob must be refused rather
// than forwarded, because forwarding it would offer a key under a false name.
expect(
    SSHAgent.wireBlob(publicKeyOpenSSH: "ssh-rsa " + keyBlob.base64EncodedString()) == nil,
    "a key whose name does not match its contents is refused"
)
expect(SSHAgent.wireBlob(publicKeyOpenSSH: "not a key") == nil, "and so is nonsense")
expect(slice(keyBlob, 0, 4), Data([0, 0, 0, 11]), "the algorithm name is 11 bytes")
expect(slice(keyBlob, 4, 11), Data("ssh-ed25519".utf8), "and spells ssh-ed25519")

// MARK: - Request identities

print("\n— a request for identities —")
var ask = Data()
ask.append(11)                      // SSH2_AGENTC_REQUEST_IDENTITIES
let answer = try! agent.handle(ask)

// The answer is: type(1) + count(4) + blob(4+n) + comment(4+n), all big-endian.
// An off-by-one in a length prefix is invisible until a server desynchronises
// two messages later.
expect(byte(answer, 0), 12, "answered with SSH2_AGENT_IDENTITIES_ANSWER")
expect(slice(answer, 1, 4), Data([0, 0, 0, 1]), "one identity was offered")
let blobLength = uint32(answer, 5)
expect(blobLength, keyBlob.count, "the blob length matches the key blob")
expect(slice(answer, 9, blobLength), keyBlob, "and the blob is the key, in wire form")
let commentLength = uint32(answer, 9 + blobLength)
let comment = slice(answer, 13 + blobLength, commentLength)
expect(comment, Data("cqutmux".utf8), "followed by the comment")
expect(answer.count, 13 + blobLength + commentLength, "with nothing left over")

// MARK: - Signing

print("\n— a signing request —")
var request = Data()
request.append(13)                  // SSH2_AGENTC_SIGN_REQUEST
appendUInt32(&request, keyBlob.count)
request.append(keyBlob)
let message = Data("the bytes to sign".utf8)
appendUInt32(&request, message.count)
request.append(message)
appendUInt32(&request, 0)           // flags

let signed = try! agent.handle(request)
expect(byte(signed, 0), 14, "answered with SSH2_AGENT_SIGN_RESPONSE")

// The signature blob is: length, then the algorithm name, then the raw
// signature. For ed25519 the raw signature is 64 bytes with no wrapper —
// unlike ECDSA, where the agent protocol wants r‖s rather than the ASN.1 form.
// Getting this backwards produces a blob that parses and then fails
// verification, which reads as a wrong key rather than a wrong encoder.
let sigLength = uint32(signed, 1)
let sig = slice(signed, 5, sigLength)
expect(uint32(sig, 0), 11, "the signature names its algorithm")
expect(slice(sig, 4, 11), Data("ssh-ed25519".utf8), "as ssh-ed25519")
expect(uint32(sig, 15), 64, "the raw signature is 64 bytes, unwrapped")
expect(slice(sig, 19, 64), fixedSignature, "and it is the bytes the signer produced")

// MARK: - Refusals

print("\n— what it refuses —")

// A request naming a different key. The agent has one identity, so a mismatch
// means the server is confused; answering with a signature would be worse than
// failing, because it would authenticate something we never offered.
var foreignRequest = Data()
foreignRequest.append(13)
let foreign = Data(repeating: 0x99, count: 40)
appendUInt32(&foreignRequest, foreign.count)
foreignRequest.append(foreign)
appendUInt32(&foreignRequest, 4)
foreignRequest.append(Data("data".utf8))
appendUInt32(&foreignRequest, 0)
expect(byte(agent.reply(for: foreignRequest), 0), 5, "a signature for an unknown key is refused")

// An unimplemented request type. SSH_AGENT_FAILURE, not silence: a server that
// gets no reply waits, and a `git push` that hangs is worse than one that the
// server can move on from.
expect(byte(agent.reply(for: Data([17])), 0), 5, "an unknown request is refused, not ignored")
expect(byte(agent.reply(for: Data()), 0), 5, "an empty message is refused")

// A signer that throws. `handle` surfaces it so a caller can say why, and
// `reply` turns it into SSH_AGENT_FAILURE — the two halves are tested
// separately because only the second one goes on the wire. A half-written
// response would desynchronise the channel, so neither may emit one.
let broken = SSHAgent(identity: identity) { _, _ in throw SSHAgent.AgentError.signingFailed("nope") }
var didThrow = false
do { _ = try broken.handle(request) } catch { didThrow = true }
expect(didThrow, "a failing signer surfaces through handle")
expect(byte(broken.reply(for: request), 0), 5, "and becomes a failure reply on the wire")

// RSA is refused by name. OpenSSH wants the full PKCS#1 blob for it, and a
// partial implementation would look like a rejected key rather than a missing
// feature.
expect(
    SSHAgent.signatureBlob(raw: fixedSignature, algorithm: .rsa) == nil,
    "rsa signing is refused rather than half-implemented"
)

// MARK: - Framing

print("\n— the wire length prefixes —")
expect(AgentWriter().data.isEmpty, "a new writer is empty")
var writer = AgentWriter()
writer.uint32(0x01020304)
expect(writer.data, Data([1, 2, 3, 4]), "uint32 is big-endian")
writer = AgentWriter()
writer.uint32(0)
expect(writer.data, Data([0, 0, 0, 0]), "zero is four bytes, not none")
writer = AgentWriter()
writer.string(Data([0xaa, 0xbb]))
expect(writer.data, Data([0, 0, 0, 2, 0xaa, 0xbb]), "a string is its length then its bytes")

// Reading must not trust the length it is handed: the value comes off the
// wire, and a huge one would otherwise ask for a huge allocation.
var reader = AgentReader(Data([0xff, 0xff, 0xff, 0xff, 0x01, 0x02]))
expect(reader.string() == nil, "an impossible length is rejected, not allocated")

print("\n\(failures == 0 ? "agent protocol check passed" : "agent protocol check FAILED (\(failures))")")
exit(failures == 0 ? 0 : 1)

func appendUInt32(_ data: inout Data, _ value: Int) {
    let v = UInt32(value)
    data.append(UInt8(v >> 24 & 0xff))
    data.append(UInt8(v >> 16 & 0xff))
    data.append(UInt8(v >> 8 & 0xff))
    data.append(UInt8(v & 0xff))
}