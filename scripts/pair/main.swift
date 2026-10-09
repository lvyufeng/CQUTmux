import Foundation

// The pairing link: what a host prints, what a camera reads, and what the app
// turns into a saved connection.
//
// Every rule here is about a string that is written on one machine and read on
// another, with no error channel between them. A field that does not survive
// the round trip is not a rejected link — it is a connection that authenticates
// as nobody, or a gateway token that is silently empty so the Inbox lists
// nothing and looks like a host with nothing happening. And the key is a
// secret travelling through a QR code, so where it sits in the URL decides
// whether it leaks into logs and chat previews.
//
// `Pairing.swift` is Foundation-only, so this needs no simulator.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)")
    }
}

// A real Ed25519 seed: 32 bytes that are usually not valid UTF-8. That is the
// case the format exists for, and the one a string-shaped key silently drops.
let seed = Data((0..<32).map { UInt8(($0 * 7 + 128) % 256) })

let full = Pairing.Payload(
    host: "10.0.0.5",
    port: 2222,
    username: "lvyufeng",
    token: "s3cret-token",
    name: "workstation",
    seed: seed
)

// MARK: - The round trip

let text = Pairing.string(for: full)
let parsed = try? Pairing.parse(text)
check(parsed != nil, "a payload survives the round trip")
check(parsed?.host == full.host, "the host survives")
check(parsed?.port == full.port, "the port survives")
check(parsed?.username == full.username, "the user survives")
check(parsed?.token == full.token, "the gateway token survives")
check(parsed?.name == full.name, "the name survives")
check(parsed?.seed == full.seed, "the private key survives")

// The point of the whole exercise. A key is 32 arbitrary bytes, and most such
// byte strings are not valid UTF-8 — so a parser that put the key through a
// `String` on the way would drop the majority of real keys without an error,
// and the failure would surface at connect time as an authentication failure
// rather than as a pairing that did not work.
let awkwardSeed = Data([0xff, 0xfe, 0x80, 0x00, 0xc3, 0x28, 0xed, 0xa0, 0x9f, 0x7f, 0x41, 0x00,
                        0x01, 0x02, 0xfb, 0xfc, 0xfd, 0x9c, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85,
                        0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d])
let awkwardSeedPayload = Pairing.Payload(host: "h", username: "u", seed: awkwardSeed)
let awkwardSeedBack = try? Pairing.parse(Pairing.string(for: awkwardSeedPayload))
check(awkwardSeedBack?.seed == awkwardSeed, "a key that is not valid UTF-8 survives byte for byte")

// And the failure direction: a key that is not base64, or is the wrong length,
// has to read as no key rather than as a truncated one. Accepting 31 bytes
// would turn a malformed link into a connection attempt with a broken key.
check((try? Pairing.parse("cqutmux://pair?v=1&host=h&user=u#key=not-base64!"))?.seed == nil,
      "a key that is not base64 reads as no key")
let short = Data(repeating: 1, count: 31).base64EncodedString()
check((try? Pairing.parse("cqutmux://pair?v=1&host=h&user=u#key=\(short)"))?.seed == nil,
      "a 31-byte key reads as no key rather than being accepted short")

// MARK: - The key is kept out of the part that travels

// A URL's fragment is not sent to a server and usually does not reach the log
// of whatever unfurled it. The key belongs there and nowhere else.
check(text.contains("#key="), "the key rides in the fragment")
let beforeFragment = text.split(separator: "#")[0]
check(!beforeFragment.contains("key="), "the key is not in the query string")
check(text.components(separatedBy: "#").count == 2, "there is exactly one fragment")

// MARK: - Characters that end a field early

// These are the characters that break a naive `urlQueryAllowed` encoding: each
// one either terminates the field or starts a new one, and the result is a
// token that arrives half-length.
let awkward = Pairing.Payload(
    host: "10.0.0.5",
    username: "user name+weird",
    token: "a&b=c#d?e f+g",
    name: "my host & yours",
    seed: awkwardSeed
)
let awkwardText = Pairing.string(for: awkward)
let awkwardBack = try? Pairing.parse(awkwardText)
check(awkwardBack?.token == awkward.token, "a token full of delimiters survives")
check(awkwardBack?.username == awkward.username, "a username with a space and a plus survives")
check(awkwardBack?.name == awkward.name, "a name with an ampersand survives")
check(awkwardBack?.seed == awkward.seed, "a key containing delimiters survives")

// MARK: - What a camera actually hands over

// A scanner is not guaranteed to strip whitespace, and a QR code printed on a
// terminal carries the newline the printer added. Rejecting that is a failure
// the user cannot see the cause of.
let padded = "\n  \(text)\n"
check((try? Pairing.parse(padded))?.host == full.host, "surrounding whitespace is tolerated")

// The scheme and host are matched case-insensitively, as URL schemes are.
check((try? Pairing.parse(text.replacingOccurrences(of: "cqutmux://pair", with: "CQUTMUX://PAIR")))?.host == full.host,
      "the scheme and route are matched case-insensitively")

// MARK: - What is refused

func refusal(_ text: String) -> Pairing.Failure? {
    do { _ = try Pairing.parse(text); return nil } catch { return error as? Pairing.Failure }
}

// A scanner sees every code in the room, so a menu's QR must be recognisably
// not ours before any error is shown.
check(Pairing.looksLikePairing(text), "a pairing link is recognised as one")
check(!Pairing.looksLikePairing("https://example.com"), "a website is not")
check(!Pairing.looksLikePairing("WIFI:S=guest;T=WPA;P=password;;"), "a wifi code is not")
check(refusal("https://example.com") == .notAPairingURL, "a website is refused as not ours")
check(refusal("cqutmux://tmux?session=x") == .notAPairingURL,
      "our own terminal deep link is not mistaken for a pairing link")

check(refusal("cqutmux://pair?v=1&user=me") == .missingHost, "a link with no host is refused")
check(refusal("cqutmux://pair?v=1&host=10.0.0.5") == .missingUsername,
      "a link with no user is refused")
check(refusal("cqutmux://pair?v=99&host=h&user=u") == .unsupportedVersion(99),
      "a link from a future version is refused rather than half-parsed")

// MARK: - Defaults

// A host at the default port should not have to say so, and a phone reading a
// link with no port must not guess zero.
let minimal = Pairing.Payload(host: "host.example", username: "me")
let minimalBack = try? Pairing.parse(Pairing.string(for: minimal))
check(minimalBack?.port == 22, "a missing port means 22, not zero")
check(minimalBack?.token == nil, "a missing token is nil, not an empty string")
check(minimalBack?.seed == nil, "a missing key is nil")

// An empty token in the URL is the same as no token: a gateway without one is a
// legitimate setup, and an empty string would be sent as `Bearer `.
let emptyToken = try? Pairing.parse("cqutmux://pair?v=1&host=h&user=u&token=")
check(emptyToken?.token == nil, "an empty token is read as no token")

// MARK: - Version

// The version is written on every link, so a future format can be told apart
// from a mistake rather than mis-parsed. Its absence is treated as 1, which is
// what every link written before the field existed would be.
check(text.contains("v=1"), "the version is written into every link")
check((try? Pairing.parse("cqutmux://pair?host=h&user=u"))?.version == 1,
      "a link with no version is read as version 1")

// MARK: - The key really is optional

// Easy Pair generates a key, but pairing to a host that already has one — or
// that uses a password — must still work.
let withoutKey = Pairing.Payload(host: "h", username: "u", token: "t")
let withoutKeyBack = try? Pairing.parse(Pairing.string(for: withoutKey))
check(withoutKeyBack?.seed == nil, "a link with no key parses")
check(withoutKeyBack?.token == "t", "and still carries the token")
check(!Pairing.string(for: withoutKey).contains("#"), "and has no empty fragment")

if failures > 0 {
    print("\nPAIR_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nPAIR_PASS  (\(checks) checks)")