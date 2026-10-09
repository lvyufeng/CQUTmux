import Foundation
import CQUTTransport

// Checks the OpenSSH private-key reader, against real keys made by ssh-keygen.
//
// The reader is the part of key import that can be quietly wrong: a key read
// from a file either works or the connection fails later with "permission
// denied (publickey)", which says nothing about the parse. So the checks do not
// stop at "it returned 32 bytes" — they compare the *public* key derived from
// the imported seed against the `.pub` line ssh-keygen wrote beside it. A
// reader that returned the wrong 32 bytes would still produce a valid-looking
// key, and only that comparison catches it.
//
// Run from `scripts/key-import-check.sh`, which makes the fixtures.

let tmp = ProcessInfo.processInfo.environment["KEY_IMPORT_TMPDIR"] ?? ""
if tmp.isEmpty {
    FileHandle.standardError.write(Data("KEY_IMPORT_TMPDIR is not set\n".utf8))
    exit(2)
}

var failures = 0
var checks = 0
func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition { print("PASS  " + label) }
    else { failures += 1; print("FAIL  " + label) }
}

func read(_ name: String) -> String {
    (try? String(contentsOfFile: tmp + "/" + name, encoding: .utf8)) ?? ""
}

// MARK: - The round trip

// ssh-keygen's own public key for the fixture, which is the only thing that
// proves the seed was read from the right offset.
let expectedPublic = read("id_ed25519.pub").trimmingCharacters(in: .whitespacesAndNewlines)
let pem = read("id_ed25519")

check(!pem.isEmpty, "the fixture private key was written")
check(pem.contains("BEGIN OPENSSH PRIVATE KEY"), "and is in OpenSSH format")

do {
    let seed = try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: pem)
    check(seed.count == 32, "the seed is 32 bytes, which is what ed25519 uses")

    let derived = try Ed25519OpenSSH.publicKey(fromSeed: seed, comment: "fixture")
    // Compare the base64 body, not the whole line: the comment differs, and
    // the comment is not part of the key.
    let derivedBody = derived.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    let expectedBody = expectedPublic.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    check(!expectedBody.isEmpty, "ssh-keygen wrote a public key to compare against")
    check(derivedBody == expectedBody,
          "the seed from the file derives exactly the public key ssh-keygen did")
    check(derived.hasPrefix("ssh-ed25519 "), "and it is an ed25519 key")
} catch {
    check(false, "the fixture key parses (\(error))")
    check(false, "the fixture key derives its public half")
    check(false, "and it is an ed25519 key")
    check(false, "and a public key exists to compare against")
}

// MARK: - Trailing whitespace and CRLF

// A key copied out of a terminal or saved by a Windows editor carries what the
// terminal or the editor added. The PEM body is assembled by dropping the
// header lines and joining, so a stray blank line is already harmless — this
// pins that, because it is the difference between "paste worked" and "paste
// silently produced key material from mangled base64".
do {
    let padded = pem + "\n\n"
    let seed = try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: padded)
    let derived = try Ed25519OpenSSH.publicKey(fromSeed: seed, comment: "fixture")
    let derivedBody = derived.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    let expectedBody = expectedPublic.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    check(derivedBody == expectedBody, "a trailing blank line does not change the key")
} catch {
    check(false, "a trailing blank line does not change the key (\(error))")
}

// MARK: - What must be refused

// The one that matters most: an encrypted key must *not* be read as if it were
// plaintext. Silently importing 32 bytes of ciphertext would store a key that
// cannot authenticate, and the failure would surface as a server-side rejection
// long after the import looked like it worked.
do {
    let encrypted = read("id_ed25519_encrypted")
    check(!encrypted.isEmpty, "the encrypted fixture was written")
    _ = try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: encrypted)
    check(false, "an encrypted key is refused rather than read as ciphertext")
} catch let error as Ed25519OpenSSH.KeyError {
    check(String(describing: error).contains("encrypted"),
          "an encrypted key is refused, and the message says why")
} catch {
    check(false, "an encrypted key is refused (\(error))")
}

do {
    let rsa = read("id_rsa")
    if rsa.isEmpty {
        check(false, "the rsa fixture was written")
    } else {
        do {
            _ = try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: rsa)
            check(false, "an RSA key is refused rather than read as an ed25519 seed")
        } catch let error as Ed25519OpenSSH.KeyError {
            check(String(describing: error).contains("ed25519")
                  || String(describing: error).contains("RSA"),
                  "an RSA key is refused with a message naming the type")
        }
    }
} catch {
    check(false, "the rsa fixture was written")
}

for (label, text) in [
    ("empty text", ""),
    ("a public key line, not a private one", expectedPublic),
    ("prose", "this is not a key at all\n"),
    ("a truncated PEM", "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"),
] {
    var refused = false
    do { _ = try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: text) } catch { refused = true }
    check(refused, "\(label) is refused")
}

// MARK: - Writing a key back out

// Export has one failure mode that matters and is invisible on the phone: a PEM
// that looks like a key but that no ssh client accepts. The check writes one
// and hands it to `ssh-keygen -y`, which is the same program the user's laptop
// will use — if it prints the public key, the file is really usable.

do {
    let (seed, line) = try Ed25519OpenSSH.generate()
    let pem = try Ed25519OpenSSH.openSSHPrivateKey(fromSeed: seed, comment: "exported")
    check(pem.contains("BEGIN OPENSSH PRIVATE KEY"), "the exported text is an OpenSSH PEM")
    check(pem.contains("END OPENSSH PRIVATE KEY"), "with a closing marker ssh-keygen looks for")

    try pem.write(toFile: tmp + "/exported", atomically: true, encoding: .utf8)
    // ssh-keygen refuses a private key file anyone else can read, whatever the
    // contents. Worth pinning as a step of its own: it is the first thing a
    // user will hit after exporting, and the message ("bad permissions") reads
    // as a corrupt key if you have never seen it before.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp + "/exported")
    let derived = try Ed25519OpenSSH.publicKey(fromSeed: seed, comment: "x")
    let derivedBody = derived.split(separator: " ").dropFirst().first.map(String.init) ?? ""

    // Compare the base64 body: the comment is not part of the key, and the two
    // sides here are written with different comments on purpose.
    let roundTripBody = (try? Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: pem))
        .flatMap { try? Ed25519OpenSSH.publicKey(fromSeed: $0, comment: "y") }
        .map { $0.split(separator: " ").dropFirst().first.map(String.init) ?? "" }
    check(roundTripBody == derivedBody,
          "and reads back to the same key through the app's own reader")

    // ssh-keygen is what the other end will use. Run through the shell only to
    // reach it; the file path is one this check wrote.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ssh-keygen", "-y", "-f", tmp + "/exported"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let outBody = out.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    check(process.terminationStatus == 0, "ssh-keygen -y accepts the exported file (\(out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    check(outBody == derivedBody, "and derives the same public key the app did")
} catch {
    check(false, "the exported text is an OpenSSH PEM (\(error))")
    check(false, "with a closing marker")
    check(false, "and reads back to the same key")
    check(false, "ssh-keygen -y accepts the exported file")
    check(false, "and derives the same public key")
}

// The empty comment is not decoration: `ssh-keygen -c` writes an empty comment
// for a key whose comment was cleared, and a writer that assumed a non-empty
// one would emit a length-prefixed string over the wrong bytes.
do {
    let (seed, _) = try Ed25519OpenSSH.generate()
    let pem = try Ed25519OpenSSH.openSSHPrivateKey(fromSeed: seed, comment: "")
    let back = try? Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: pem)
    check(back == seed, "a key with an empty comment still round-trips")
} catch {
    check(false, "a key with an empty comment still round-trips (\(error))")
}

// MARK: - Generation round-trips through the same reader

// `generate()` is what a user without a key file gets. It does not go through
// the PEM reader, so if the two disagreed the app would generate keys the
// import path could not read back — worth pinning since they are separate code.
do {
    let (seed, line) = try Ed25519OpenSSH.generate()
    check(seed.count == 32, "a generated seed is 32 bytes")
    let body = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    let derived = try Ed25519OpenSSH.publicKey(fromSeed: seed, comment: "x")
    let derivedBody = derived.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    check(body == derivedBody, "a generated key's public line matches its own seed")
} catch {
    check(false, "a generated seed is 32 bytes (\(error))")
    check(false, "a generated key's public line matches its own seed")
}

print("")
if failures == 0 {
    print("KEY_IMPORT_PASS  (\(checks) checks)")
} else {
    print("KEY_IMPORT_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}