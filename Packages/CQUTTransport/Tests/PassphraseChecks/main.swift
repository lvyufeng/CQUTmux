import Foundation
import CQUTTransport

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
var failures = 0, checks = 0
func check(_ c: Bool, _ l: String) { checks += 1; if c { print("PASS  " + l) } else { failures += 1; print("FAIL  " + l) } }

let tmp = ProcessInfo.processInfo.environment["KEY_IMPORT_TMPDIR"] ?? ""

// Reading an encrypted fixture off disk, through the shipped decision layer.
let plainPem = (try? String(contentsOfFile: tmp + "/id_ed25519", encoding: .utf8)) ?? ""
let encPem = (try? String(contentsOfFile: tmp + "/id_ed25519_encrypted", encoding: .utf8)) ?? ""

// --- decode: a bare seed versus a stored PEM ---------------------------------
let (seed, _) = try Ed25519OpenSSH.generate()
check(KeyMaterial.decode(seed) == .seed(seed), "a 32-byte blob decodes as a seed")
check(KeyMaterial.decode(Data(encPem.utf8)) == .encryptedKey(encPem),
      "an encrypted PEM decodes as an encrypted key")
check(KeyMaterial.decode(Data()) == nil, "an empty blob decodes to nothing")
check(KeyMaterial.decode(Data("hello".utf8)) == nil, "arbitrary bytes decode to nothing")
check(KeyMaterial.encode(.seed(seed)) == seed, "a seed round-trips through encode")

// --- requirement: the decision the connect flow acts on ----------------------
check(KeyMaterial.requirement(for: nil, passphrase: nil) == .missing,
      "nothing stored needs nothing but is recognised as missing")
check(KeyMaterial.requirement(for: seed, passphrase: nil) == .ready,
      "a bare seed is ready with no passphrase")
check(KeyMaterial.requirement(for: Data(encPem.utf8), passphrase: nil) == .passphraseNeeded,
      "an encrypted key with no stored passphrase asks for one")
check(KeyMaterial.requirement(for: Data(encPem.utf8), passphrase: "a passphrase") == .unlocked,
      "an encrypted key with its stored passphrase is unlocked")
check(KeyMaterial.requirement(for: Data(encPem.utf8), passphrase: "wrong") == .passphraseNeeded,
      "a stored passphrase that no longer opens the key asks again rather than claiming unlocked")
check(KeyMaterial.requirement(for: Data("junk".utf8), passphrase: nil) == .unrecognised,
      "something stored that is neither form is reported as unrecognised")

// --- seed(): the same decisions, taking the passphrase -----------------------
do {
    let got = try KeyMaterial.seed(from: seed, passphrase: nil)
    check(got == seed, "a bare seed comes back unchanged")
} catch { check(false, "a bare seed comes back unchanged (\(error))") }

do {
    let got = try KeyMaterial.seed(from: Data(encPem.utf8), passphrase: "a passphrase")
    let pub = try Ed25519OpenSSH.publicKey(fromSeed: got, comment: "x")
    let want = ((try? String(contentsOfFile: tmp + "/id_ed25519_encrypted.pub", encoding: .utf8)) ?? "")
        .split(separator: " ").dropFirst().first.map(String.init) ?? ""
    check(pub.split(separator: " ").first.map(String.init) != nil && pub.contains(want),
          "an encrypted key opens with its passphrase to the seed ssh-keygen wrote")
} catch { check(false, "an encrypted key opens with its passphrase (\(error))") }

do {
    _ = try KeyMaterial.seed(from: Data(encPem.utf8), passphrase: nil)
    check(false, "an encrypted key with no passphrase refuses rather than returning ciphertext")
} catch KeyMaterial.Failure.passphraseRequired {
    check(true, "an encrypted key with no passphrase refuses with passphraseRequired")
} catch { check(false, "an encrypted key refuses with the right reason (\(error))") }

do {
    _ = try KeyMaterial.seed(from: nil, passphrase: "anything")
    check(false, "nothing stored refuses")
} catch KeyMaterial.Failure.nothingStored {
    check(true, "nothing stored refuses with nothingStored")
} catch { check(false, "nothing stored refuses with the right reason (\(error))") }

// An empty passphrase must be treated as "not supplied", not as a passphrase
// that happens to be empty: `looksEncrypted` probes with "" and a reader that
// accepted it would report every encrypted key as unencrypted.
do {
    _ = try KeyMaterial.seed(from: Data(encPem.utf8), passphrase: "")
    check(false, "an empty passphrase is not mistaken for a real one")
} catch KeyMaterial.Failure.passphraseRequired {
    check(true, "an empty passphrase is treated as no passphrase at all")
} catch { check(false, "an empty passphrase is treated as absent (\(error))") }

// The plain fixture still bites: a seed stored from it must be a seed, and
// `decode` must not mistake the PEM for one just because the parse succeeds.
do {
    let s = try Ed25519OpenSSH.seed(fromOpenSSHPrivateKey: plainPem)
    check(KeyMaterial.decode(s) == .seed(s), "the seed of an unencrypted key decodes as a seed")
    check(KeyMaterial.requirement(for: s, passphrase: "unrelated") == .ready,
          "a bare seed ignores a passphrase that happens to be stored")
} catch { check(false, "the plain fixture parses (\(error))") }

// The cost the user actually pays, printed rather than asserted: the derivation
// runs on the main thread when the connect flow resolves a key, and bcrypt is
// deliberately slow. A regression here (a round count misread as something
// larger, say) would still be correct and would make the app look hung.
do {
    let start = Date()
    _ = try BcryptPBKDF.derive(
        passphrase: "hunter2",
        salt: Array(0..<16).map { UInt8($0) },
        rounds: 24,
        length: 48
    )
    print(String(format: "NOTE  a 24-round key derivation takes %.2fs", Date().timeIntervalSince(start)))
} catch {
    check(false, "the timing derivation runs (\(error))")
}

print("")
if failures == 0 { print("PASSPHRASE_PASS  (\(checks) checks)") }
else { print("PASSPHRASE_FAIL  (\(failures) of \(checks) failed)"); exit(1) }
