import Foundation

// The link format, driven from the shell: `scripts/cli-check.sh` uses this to
// read what `cqutmux pair` printed with the *app's own* parser, rather than
// with a second reading written in the check.
//
// That distinction is the whole point. Comparing the host's output against the
// host's own idea of the format proves only that it agrees with itself; the
// question is whether the app — the other implementation — can read it. So this
// links `Pairing.swift`, the file the app ships.
//
//   parse build          JSON on stdin -> the link on stdout
//   parse link <url>     the link -> JSON of the fields on stdout
//
// Exits non-zero with a message on stderr when a link will not parse.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let mode = arguments.first else { fail("usage: parse build | parse link <url>") }

switch mode {
case "build":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let raw = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else {
        fail("could not read a payload from stdin")
    }
    var payload = Pairing.Payload(
        host: raw["host"] as? String ?? "",
        port: raw["port"] as? Int ?? 22,
        username: raw["username"] as? String ?? ""
    )
    payload.token = raw["token"] as? String
    payload.name = raw["name"] as? String
    if let key = raw["key"] as? String { payload.key = key }
    print(Pairing.string(for: payload))

case "link":
    guard arguments.count > 1 else { fail("parse link needs a URL") }
    do {
        let payload = try Pairing.parse(arguments[1])
        var out: [String: Any] = [
            "host": payload.host,
            "port": payload.port,
            "username": payload.username,
            "version": payload.version,
        ]
        if let token = payload.token { out["token"] = token }
        if let name = payload.name { out["name"] = name }
        // The seed as hex, so a check can prove two links carry the *same* key
        // rather than merely both carrying one.
        if let seed = payload.seed { out["keyHex"] = seed.map { String(format: "%02x", $0) }.joined() }
        out["keyBytes"] = payload.seed?.count ?? 0
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } catch {
        fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }

default:
    fail("unknown mode: \(mode)")
}