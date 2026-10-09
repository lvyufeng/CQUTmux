import Foundation

/// The text a host prints (and shows as a QR code) so a phone can be set up from
/// it in one scan.
///
/// Moshi calls this Easy Pair and describes it as setting up "SSH/Mosh host
/// access" — the connection and its key, not the `moshi-hook` token, which is a
/// separate pairing. This carries both, because a phone that has the address
/// but not the gateway token shows an Inbox that silently lists nothing.
///
/// A URL rather than a JSON blob for one reason: `cqutmux://` is the scheme the
/// app already registers, so the same string that a camera reads is also a link
/// that can be sent in a message or opened from a terminal's own output. The
/// QR is a rendering of this, not a second format.
///
/// Foundation-only, so both the app and `scripts/pair-check.sh` can use it.
enum Pairing {
    /// The scheme and host of the URL. `cqutmux://pair?...`.
    static let scheme = "cqutmux"

    struct Payload: Equatable {
        var host: String
        var port: Int = 22
        var username: String
        /// The gateway's bearer token, if it sets one. Optional because a
        /// gateway without `--token` legitimately has none, and refusing to
        /// pair with it would be wrong — it is the same host over the same
        /// tunnel.
        var token: String?
        /// Name to save the connection under. Defaults to the hostname the
        /// printer knows itself by, which is more use than the address.
        var name: String?
        /// The private key: the 32-byte Ed25519 seed, base64.
        ///
        /// Bytes rather than a string, and that is not a detail. A random key is
        /// usually not valid UTF-8, so carrying it as a `String` means the
        /// bytes are base64-encoded for the URL, decoded back by the parser,
        /// and then run through `String(data:encoding:.utf8)` — which returns
        /// nil for most keys and drops them without a word. The host would
        /// print a link that scans, the phone would accept it, and the
        /// connection would fail authentication. Bytes all the way through is
        /// the only form with nothing to lose in.
        ///
        /// The *seed*, not the OpenSSH text file: it is what the app stores, so
        /// no format conversion can go wrong between two languages; it is 44
        /// characters instead of about 400, which keeps the QR code small
        /// enough to print in a terminal and scan from a phone; and the OpenSSH
        /// encoding of the same key differs between generators, so parsing it
        /// here would mean trusting a second implementation of a format this
        /// app already reads.
        ///
        /// A fragment because fragments are not sent to servers: if this URL
        /// ends up in a log, a chat message that unfurls, or a proxy, the key
        /// is not in the part that travels. It is still in the string, so the
        /// QR code is a secret and the command says so.
        var seed: Data?

        /// The seed as base64 text, for the link.
        var key: String? {
            get { seed?.base64EncodedString() }
            set {
                // Percent-decoding first: the base64 was escaped into the URL,
                // and `+` and `=` are among the characters that do not survive
                // it untouched.
                guard let newValue,
                      let data = Data(base64Encoded: newValue.removingPercentEncoding ?? newValue)
                else { seed = nil; return }
                seed = data
            }
        }

        /// Version of the format, so a future change can be detected rather
        /// than mis-parsed. Present in every URL this writes.
        var version: Int = 1
    }

    enum Failure: Error, Equatable, LocalizedError {
        case notAPairingURL
        case unsupportedVersion(Int)
        case missingHost
        case missingUsername

        var errorDescription: String? {
            switch self {
            case .notAPairingURL:
                "That is not a CQUTmux pairing link."
            case .unsupportedVersion(let version):
                "That pairing link is version \(version), which this build does not know."
            case .missingHost:
                "The pairing link does not say which host to connect to."
            case .missingUsername:
                "The pairing link does not say which user to log in as."
            }
        }
    }

    // MARK: - Writing

    /// The URL for a payload.
    ///
    /// Query for everything but the key, which goes in the fragment — see
    /// `Payload.key`.
    static func string(for payload: Payload) -> String {
        var items: [String] = ["v=\(payload.version)"]
        items.append("host=\(escape(payload.host))")
        if payload.port != 22 { items.append("port=\(payload.port)") }
        items.append("user=\(escape(payload.username))")
        if let token = payload.token, !token.isEmpty {
            items.append("token=\(escape(token))")
        }
        if let name = payload.name, !name.isEmpty {
            items.append("name=\(escape(name))")
        }
        var text = "\(scheme)://pair?" + items.joined(separator: "&")
        if let key = payload.key, !key.isEmpty {
            text += "#key=" + escape(key)
        }
        return text
    }

    // MARK: - Reading

    /// Parses a URL, or the URL inside a QR code's text.
    ///
    /// Accepts leading and trailing whitespace, because a QR code scanned off a
    /// terminal's own output carries the newline the printer added, and a scan
    /// that fails for a reason nobody can see is worse than one that fails
    /// loudly.
    static func parse(_ text: String) throws -> Payload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == "pair"
        else { throw Failure.notAPairingURL }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            // First wins: a duplicated key is either a malformed link or an
            // attempt to smuggle a second value past a reader that takes the
            // last, and neither is worth honouring.
            if values[item.name] == nil { values[item.name] = item.value ?? "" }
        }
        // The fragment carries the key. `URLComponents` gives it whole, so it
        // is split by hand rather than by `queryItems`, which would re-join it
        // wrongly if the base64 contained an `=`.
        var fragment: [String: String] = [:]
        if let raw = components.fragment {
            for pair in raw.split(separator: "&") {
                guard let equals = pair.firstIndex(of: "=") else { continue }
                let name = String(pair[pair.startIndex..<equals])
                let value = String(pair[pair.index(after: equals)...])
                if fragment[name] == nil { fragment[name] = value }
            }
        }

        let version = values["v"].flatMap(Int.init) ?? 1
        guard version == 1 else { throw Failure.unsupportedVersion(version) }

        guard let host = values["host"], !host.isEmpty else { throw Failure.missingHost }
        guard let user = values["user"], !user.isEmpty else { throw Failure.missingUsername }

        return Payload(
            host: host,
            port: values["port"].flatMap(Int.init) ?? 22,
            username: user,
            token: values["token"].flatMap { $0.isEmpty ? nil : $0 },
            name: values["name"].flatMap { $0.isEmpty ? nil : $0 },
            seed: checkSeed(fragment["key"]),
            version: version
        )
    }

    /// Whether a scanned string is one of ours at all.
    ///
    /// The scanner sees every QR code in the room. Without this, pointing the
    /// camera at a restaurant menu reports "that is not a pairing link" for
    /// something that was never meant to be one.
    static func looksLikePairing(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("\(scheme)://pair")
    }

    // MARK: - Encoding details

    /// Percent-encodes a value for a query or fragment.
    ///
    /// `urlQueryAllowed` is not enough on its own: it permits `&`, `=` and `#`,
    /// any of which in a token or a password would end the field early and
    /// silently truncate what the other end receives.
    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#? ")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// The 32-byte seed a key field carries, or nil if it is not one.
    ///
    /// Returns `Data`, not `String`, on purpose — see `Payload.seed`. A key is
    /// 32 arbitrary bytes, and most such byte strings are not valid UTF-8, so a
    /// parser that went through a `String` here would reject the majority of
    /// real keys without an error.
    ///
    /// The length check is here rather than at the point of use so that a
    /// malformed field reads as "no key". A 31-byte value is not a key, and
    /// accepting it would turn a mistyped or truncated link into a connection
    /// that fails authentication later, which is a much harder failure to
    /// trace back to pairing than a form that says the key is missing.
    private static func checkSeed(_ text: String?) -> Data? {
        guard let text else { return nil }
        // Percent-decoding first: the base64 was escaped into the URL, and `+`
        // and `=` are among the characters that do not survive it untouched.
        let decoded = text.removingPercentEncoding ?? text
        guard let data = Data(base64Encoded: decoded), data.count == 32 else { return nil }
        return data
    }
}