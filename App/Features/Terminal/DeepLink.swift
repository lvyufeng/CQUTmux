import Foundation

/// A link that opens the app on a specific host, session or window.
///
/// Moshi's shape is kept, including the `session` spelling for the tmux name,
/// because these URLs get pasted into terminals, webhooks and chat — a link
/// that works in one app and not the other is a link people stop trusting:
///
///   cqutmux://tmux?session=<name>[&window=<n>][&pane=<n>]
///   cqutmux://zellij?session=<name>
///   cqutmux://herdr?workspace=<id>[&session=<name>][&tab=<w1:t2>][&pane=<id>]
///   cqutmux://host?host=<name-or-hostname>
///   cqutmux://theme
///   cqutmux://inbox
///   cqutmux://usage
///
/// A host is optional and, when absent, resolves to the only saved host — a
/// link from a notification usually does not need to name the machine, and the
/// common case here is one host.
struct DeepLink: Equatable {
    enum Target: Equatable {
        /// Attach to a multiplexer session, optionally landing on a window and a
        /// pane inside it.
        ///
        /// `window` and `pane` are strings because not every mux addresses them
        /// by number — herdr uses a tab id like `w1:t2` and an opaque
        /// `pane_id`, while the same value rides in `window` whether the link
        /// spelled it `window` or `tab`.
        case session(mux: String, name: String, window: String?, pane: String?)
        case host(String)
        /// Open the theme import screen. Moshi's `moshi://theme` exists so a
        /// gallery page can hand a theme straight to the app rather than
        /// making the user copy and paste it.
        case theme
        /// Open the Inbox. What a Live Activity's tap target uses: a
        /// notification is about a pending approval, and the answer to it is on
        /// the Inbox, so a tap that opened the app on whatever tab was last
        /// used would be a tap that made the user navigate.
        case inbox
        /// Open the Usages tab. What the watch complication's tap target uses:
        /// the complication shows one rate-limit number, so a tap that opened
        /// the app on the last-used tab would be a tap that made the wearer go
        /// looking for the screen the number came from.
        case usage
    }

    var target: Target
    /// The scheme's authority, so `cqutmux:tmux?...` and
    /// `cqutmux://tmux?...` both work. UIKit normalises the former to the
    /// latter, but a URL built by hand may not.
    static let scheme = "cqutmux"

    enum ParseError: Error, LocalizedError {
        case unknownRoute(String)
        case missingParameter(String)
        case badWindow(String)
        case badPane(String)

        var errorDescription: String? {
            switch self {
            case .unknownRoute(let route):
                return "“\(route)” is not a link CQUTmux understands."
            case .missingParameter(let name):
                return "The link is missing its \(name)."
            case .badWindow(let value):
                return "“\(value)” is not a window number."
            case .badPane(let value):
                return "“\(value)” is not a pane number."
            }
        }
    }

    static func parse(_ url: URL) -> Result<DeepLink, ParseError> {
        guard url.scheme?.lowercased() == scheme else {
            return .failure(.unknownRoute(url.scheme ?? url.absoluteString))
        }

        // `cqutmux://tmux` puts the route in `host`; `cqutmux:tmux` puts it in
        // `path`. Both are accepted rather than picking one and rejecting links
        // that look identical to a user.
        let route = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .lowercased()
        guard !route.isEmpty else { return .failure(.unknownRoute("")) }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        switch route {
        case "tmux", "zellij", "herdr":
            guard let name = value("session") ?? value("workspace") else {
                return .failure(.missingParameter("session"))
            }
            // tmux and zellij take a number here, and a typo should be caught
            // rather than typed at the shell; herdr takes an opaque tab id, so
            // the value is only checked when the mux expects a number.
            //
            // `tab` is herdr's spelling and `window` is the shared one, and
            // both mean the same thing: the tab/window to land on. herdr is the
            // only mux whose links say `tab`, so the alias is read there and a
            // stray `tab=` on a tmux link is simply ignored rather than landing
            // the user somewhere the picker never offered.
            let window = value("window") ?? (route == "herdr" ? value("tab") : nil)
            if route != "herdr", let window, Int(window) == nil {
                return .failure(.badWindow(window))
            }
            // `pane` is read wherever the mux can address one, and its shape is
            // the mux's own: tmux addresses a pane by its index, so a typo is
            // caught at the parse rather than typed at the shell; herdr
            // addresses a pane by an opaque `pane_id` from its snapshot, the
            // same kind of value as its tab, so a number check there would
            // reject every valid link. zellij addresses neither a window nor a
            // pane, so it takes no `pane` — the asymmetry is the muxes' own,
            // not ours to paper over.
            let pane = (route == "tmux" || route == "herdr") ? value("pane") : nil
            if route == "tmux", let pane, Int(pane) == nil {
                return .failure(.badPane(pane))
            }
            return .success(DeepLink(target: .session(mux: route, name: name, window: window, pane: pane)))

        case "host":
            guard let name = value("host") ?? value("name") else {
                return .failure(.missingParameter("host"))
            }
            return .success(DeepLink(target: .host(name)))

        case "theme":
            return .success(DeepLink(target: .theme))

        case "inbox":
            return .success(DeepLink(target: .inbox))

        case "usage":
            return .success(DeepLink(target: .usage))

        default:
            return .failure(.unknownRoute(route))
        }
    }

    /// The session a link asks to attach to, if it names one.
    ///
    /// Deliberately not a command string: the terminal already knows how to
    /// attach and how to jump to a window, and a second copy of those commands
    /// here would be a second thing to keep in step with the session picker.
    /// The caller hands these to the same `attachSession` / `selectWindow` the
    /// picker calls, so a link and a tap cannot drift apart.
    var session: (mux: String, name: String, window: String?, pane: String?)? {
        guard case .session(let mux, let name, let window, let pane) = target else { return nil }
        return (mux, name, window, pane)
    }
}