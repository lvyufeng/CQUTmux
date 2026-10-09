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

// MARK: - Encrypted keys

// The derivation is the whole of this feature, and it cannot be checked by
// looking at it: `bcrypt_pbkdf` is a wall of wrapping arithmetic where every
// constant and every rotation has to be exactly right, and a wrong one still
// produces 32 plausible bytes. So it is pinned twice, from two directions.
//
// First against the published vector, which is the same one the `bcrypt`
// Python package's own test suite uses (`bcrypt.kdf(b"password", b"salt", 32,
// 4)`). That catches a broken derivation on its own, with no file involved.
//
// Then against a key ssh-keygen wrote with a passphrase, which is what catches
// a derivation that is right in isolation but wired up wrong — the AES key and
// IV swapped, the salt read from the wrong offset, the rounds treated as a byte
// count. Only a real key exercises those, and only comparing the *public* half
// catches them: a wrong passphrase and a wrong derivation both produce 32 bytes.

let knownVector = "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9"
do {
    let derived = try BcryptPBKDF.derive(
        passphrase: "password",
        salt: Array("salt".utf8),
        rounds: 4,
        length: 32
    )
    let hex = derived.map { String(format: "%02x", $0) }.joined()
    check(hex == knownVector, "bcrypt_pbkdf matches the published vector for password/salt/4 rounds")
} catch {
    check(false, "bcrypt_pbkdf matches the published vector (\(error))")
}

// A second vector at a different length, which is the only way to exercise the
// output-scatter path: with 32 bytes the block count is one and the
// interleaving is a no-op, so a reader that got it wrong would still agree with
// the first vector.
do {
    let derived = try BcryptPBKDF.derive(
        passphrase: "password",
        salt: Array("salt".utf8),
        rounds: 4,
        length: 48
    )
    let hex = derived.map { String(format: "%02x", $0) }.joined()
    // Note this does *not* start with the 32-byte vector: the reference
    // deliberately scatters the blocks rather than concatenating them, so a
    // longer output changes the earlier bytes too. An implementation that
    // output the blocks in order would pass the first vector and fail this one.
    check(hex == "5ba4bfc60c7ac272931458407f4c1c4936ea356c55125c5a279b791d65bf9842"
                  + "d49d7e1b572a9052715ebfa9421e7e94",
          "bcrypt_pbkdf still matches when the output crosses a block boundary")
} catch {
    check(false, "bcrypt_pbkdf still matches across a block boundary (\(error))")
}

// The encrypted fixture decrypts to the same key ssh-keygen wrote beside it.
do {
    let encrypted = read("id_ed25519_encrypted")
    check(!encrypted.isEmpty, "the encrypted fixture was written")
    let seed = try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: encrypted, passphrase: "a passphrase")
    check(seed.count == 32, "a passphrase-protected key decrypts to 32 bytes of key material")

    let derived = try Ed25519OpenSSH.publicKey(fromSeed: seed, comment: "fixture")
    let derivedBody = derived.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    // ssh-keygen refuses to print the public key of an encrypted file without
    // the passphrase, but it wrote the .pub beside it when the key was made —
    // and that file is the authority on what the key is.
    let expectedBody = read("id_ed25519_encrypted.pub")
        .split(separator: " ").dropFirst().first.map(String.init) ?? ""
    check(!expectedBody.isEmpty, "ssh-keygen wrote a public key for the encrypted fixture")
    check(derivedBody == expectedBody,
          "the decrypted seed derives exactly the public key ssh-keygen wrote beside it")
} catch {
    check(false, "a passphrase-protected key decrypts to 32 bytes (\(error))")
    check(false, "and derives its public half")
    check(false, "and a public key exists to compare against")
    check(false, "and it matches")
}

// MARK: - What must be refused

// An encrypted key with no passphrase must *not* be read as if it were
// plaintext. Silently importing 32 bytes of ciphertext would store a key that
// cannot authenticate, and the failure would surface as a server-side rejection
// long after the import looked like it worked.
do {
    let encrypted = read("id_ed25519_encrypted")
    _ = try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: encrypted)
    check(false, "an encrypted key with no passphrase is refused rather than read as ciphertext")
} catch let error as Ed25519OpenSSH.KeyError {
    check(String(describing: error).lowercased().contains("passphrase"),
          "an encrypted key is refused, and the message asks for the passphrase")
} catch {
    check(false, "an encrypted key with no passphrase is refused (\(error))")
}

// A wrong passphrase has to be reported as one, not as a corrupt file. The two
// look identical after decryption — the check integers are simply unequal — and
// telling them apart is the difference between the user retyping and the user
// giving up.
do {
    let encrypted = read("id_ed25519_encrypted")
    _ = try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: encrypted, passphrase: "not the passphrase")
    check(false, "a wrong passphrase is refused")
} catch let error as Ed25519OpenSSH.KeyError {
    check(String(describing: error).lowercased().contains("passphrase"),
          "a wrong passphrase is reported as a passphrase problem")
} catch {
    check(false, "a wrong passphrase is refused (\(error))")
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

// MARK: - Encryption, verified by ssh-keygen

// The check above proves the reader decrypts what OpenSSH writes. This proves
// the writer produces something OpenSSH accepts — which is the other direction
// of the same format, and the one a user hits when they export a key.
//
// It does not stop at "ssh-keygen read it". `ssh-keygen -p -P old -N new`
// re-encrypts the file, and if OpenSSH decoded our encryption into the right
// bytes it re-encrypts *those* bytes; the public half it prints then has to
// match. A file we encrypted with a misplaced IV would decrypt under OpenSSH
// into different pairs of check integers and be rejected much earlier, so this
// is really a check that the whole container — cipher, kdf options, salt,
// rounds, padding — is laid out the way the format says.
do {
    let (seed, _) = try Ed25519OpenSSH.generate()
    let derived = try Ed25519OpenSSH.publicKey(fromSeed: seed, comment: "x")
    let derivedBody = derived.split(separator: " ").dropFirst().first.map(String.init) ?? ""

    // A fixed salt and round count, so a failure is reproducible and the check
    // does not depend on the random salt this would otherwise use.
    let pem = try Ed25519OpenSSH.openSSHPrivateKey(
        fromSeed: seed,
        comment: "encrypted-export",
        passphrase: "hunter2",
        salt: Data((0..<16).map { UInt8($0) }),
        rounds: 16
    )
    check(pem.contains("BEGIN OPENSSH PRIVATE KEY"), "an encrypted export is an OpenSSH PEM")

    let path = tmp + "/exported_encrypted"
    try pem.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

    // `-y -P` decrypts with the passphrase and prints the public key. If the
    // passphrase or the ciphertext is wrong it fails rather than printing
    // anything, so termination status is most of the signal.
    func sshKeygen(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ssh-keygen"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    let read = sshKeygen(["-y", "-P", "hunter2", "-f", path])
    let readBody = read.output.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    check(read.status == 0, "ssh-keygen decrypts an exported encrypted key with its passphrase")
    check(readBody == derivedBody, "and gets the same public key the app derived")

    // The wrong passphrase must not decrypt it. This is the check that the
    // encryption actually happened: a writer that quietly wrote plaintext
    // would pass everything above and fail here.
    let wrong = sshKeygen(["-y", "-P", "wrong", "-f", path])
    check(wrong.status != 0, "ssh-keygen refuses the wrong passphrase on it")

    // Changing the passphrase through OpenSSH round-trips our format through
    // its writer and back through its reader.
    let changed = sshKeygen(["-p", "-P", "hunter2", "-N", "second", "-f", path])
    check(changed.status == 0, "ssh-keygen can change the passphrase on it")
    let reread = sshKeygen(["-y", "-P", "second", "-f", path])
    let rereadBody = reread.output.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    check(rereadBody == derivedBody, "and the key is unchanged after OpenSSH re-encrypts it")

    // Finally the app reads back what OpenSSH re-encrypted, which is the loop
    // closed in both directions.
    let rewritten = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    let back = try? Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: rewritten, passphrase: "second")
    check(back == seed, "the app reads back the file OpenSSH re-encrypted")
} catch {
    check(false, "an encrypted export is an OpenSSH PEM (\(error))")
    check(false, "ssh-keygen decrypts it with its passphrase")
    check(false, "and gets the same public key")
    check(false, "ssh-keygen refuses the wrong passphrase on it")
    check(false, "ssh-keygen can change the passphrase on it")
    check(false, "and the key is unchanged after OpenSSH re-encrypts it")
    check(false, "the app reads back the file OpenSSH re-encrypted")
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