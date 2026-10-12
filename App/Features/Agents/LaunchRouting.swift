import Foundation
import UserNotifications

/// The decisions the app makes when a notification arrives, and when it
/// launches with nothing telling it what to do.
///
/// Both live here rather than in the view and the app delegate that call them,
/// because both fail in the same silent way. A tap that lands nowhere looks
/// exactly like a tap the user did not make, and a launch that reconnects
/// nothing looks exactly like a feature that was never built — neither throws,
/// neither logs, and in the first case the approval the notification was about
/// simply waits behind a tab nobody opened.
///
/// Foundation-only — the one import beyond it is `UserNotifications`, for the
/// two action identifiers the system itself defines — so
/// `scripts/launch-check.sh` can drive every rule below without a simulator, an
/// app bundle or a device.
enum NotificationAction {
    /// The category the gateway's alert pushes carry. It has to be the exact
    /// string the host sends (`host/cqutmux-hook/push.mjs`) or the banner
    /// arrives with no Allow/Deny buttons — and nothing reports that: the
    /// notification looks like any other, it just cannot be answered.
    /// `scripts/launch-check.sh` reads the host's copy and compares, because a
    /// rename on either side is otherwise invisible.
    static let category = "CQUT_APPROVAL"
    /// The two button identifiers. Registered by `PushCoordinator` and read
    /// back from a response here; kept in one place so the registration and the
    /// match cannot drift.
    static let allow = "CQUT_ALLOW"
    static let deny = "CQUT_DENY"
}

/// What a notification response asks the app to do.
enum NotificationRoute: Equatable {
    /// A tap on the notification's body: open the Inbox, where the event and
    /// its Allow/Deny are.
    ///
    /// Carries no event id. The Inbox is the destination either way, and an id
    /// nothing reads would be a claim that this routes more finely than it
    /// does — naming the session the tap was about needs the Inbox's own view,
    /// not the shell's.
    case open
    /// A banner button answered the event.
    case decide(eventId: Int, allow: Bool)
    /// A dismissal, or an action this build does not know. The system expects
    /// a response to be handled, not to be obeyed.
    case none
}

enum NotificationRouting {
    /// The event a notification names, when it names one.
    ///
    /// Read as either a number or a string: the gateway sends a JSON number,
    /// but `userInfo` round-trips through `NSNumber` and a hand-made payload
    /// can carry a string.
    static func eventId(from userInfo: [AnyHashable: Any]) -> Int? {
        (userInfo["eventId"] as? Int) ?? (userInfo["eventId"] as? String).flatMap(Int.init)
    }

    /// What a response asks for.
    ///
    /// A tap on the body is the case this exists for. It carries no action
    /// identifier of its own — the system sends
    /// `UNNotificationDefaultActionIdentifier` — so it used to fall through the
    /// old switch and do nothing at all: the app opened wherever it was, on
    /// whatever tab it had last been left, and the approval the notification
    /// was about stayed behind the tab the user then had to find.
    ///
    /// A button on a notification that names no event resolves to `.none`
    /// rather than to a decision: there is nothing to answer, and an id is not
    /// something to invent for one.
    ///
    /// The old code did build a placeholder `(0, true)` in this case, but the
    /// placeholder never reached the host — `PushCoordinator.received`
    /// re-derived the id from `userInfo` and bailed on a nil id before it read
    /// the decision at all. So this is a simplification rather than a bug fix,
    /// and the distinction is worth keeping: it is the reason the two spellings
    /// are behaviourally the same, not evidence that the old one was broken.
    static func route(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> NotificationRoute {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            return .open
        case NotificationAction.allow:
            guard let id = eventId(from: userInfo) else { return .none }
            return .decide(eventId: id, allow: true)
        case NotificationAction.deny:
            guard let id = eventId(from: userInfo) else { return .none }
            return .decide(eventId: id, allow: false)
        default:
            // `UNNotificationDismissActionIdentifier`, and any action a future
            // build registers that this one does not know.
            return .none
        }
    }

    /// Whether a notification may be shown at all.
    ///
    /// The remote path and the local one read this same rule. A "pause
    /// notifications" switch that quieted pushes and left local banners
    /// arriving would be the bug a user notices exactly when they most want
    /// quiet — and they would notice it as the *switch* being broken, because
    /// the two paths cover the same approvals and nothing on screen says which
    /// one produced a banner.
    static func mayPresent(isPaused: Bool) -> Bool { !isPaused }

    /// The events worth a local banner.
    ///
    /// The pause is applied here rather than at the call site so the local path
    /// cannot be written without it, and so it is the same rule
    /// (`mayPresent`) the remote path consults — `scripts/launch-check.sh`
    /// asserts the two agree rather than trusting that they do.
    static func localNotifications(for events: [AgentEvent], isPaused: Bool) -> [AgentEvent] {
        guard mayPresent(isPaused: isPaused) else { return [] }
        return events.filter(\.isPending)
    }

    /// Where a tap on a notification lands.
    ///
    /// A link rather than a direct tab change, so the tap takes the same
    /// `handle(url)` path a pasted `cqutmux://` link does and the two cannot
    /// drift.
    ///
    /// Ungated on purpose. `cqutmux://inbox` honours the Live Activity's "Open
    /// Inbox on tap" preference, but that setting is about activities the user
    /// chose to put on the Lock Screen; a notification tap has nowhere else to
    /// go — the notification *is* the thing asking.
    static var inboxLink: URL? {
        var components = URLComponents()
        components.scheme = DeepLink.scheme
        components.host = "notification"
        return components.url
    }
}

/// The link a notification tap produced, waiting for a view to hand it to.
///
/// `didReceive(_:withCompletionHandler:)` can run before the app has a window —
/// on the launch that a tap causes, it runs first — and there is no view to
/// hand a URL to at that moment. The app reads this once, at the top of
/// `CQUTmuxApp.init`, and passes it into `RootView`; the tap then routes
/// through the same `handle(url)` path any other link reaches, so a
/// cold-launch tap and a tap on a running app cannot take different paths.
///
/// **Two readers, not one.** `init` runs once per process, so a stash that only
/// `init` reads is a stash that drops every tap made while the app is already
/// running — the common case for a banner tapped from the Lock Screen, and the
/// case the whole path exists for. `deliver` therefore also announces itself on
/// `NotificationCenter`, and `RootView` listens. The announcement carries no
/// URL on purpose: the observer calls `take()`, so a tap is handled by whichever
/// reader runs first and the other gets nil. That is what keeps the double
/// delivery from becoming a double *navigation* on cold launch, where both
/// readers are live.
///
/// `nonisolated(unsafe)` with a lock rather than a main-actor type: the
/// delegate callback is not on the main thread and neither is the app's `init`
/// guaranteed to be, and a missing lock here would be a link silently dropped
/// — the one failure this whole path exists to prevent.
final class OpenLink: @unchecked Sendable {
    static let shared = OpenLink()

    /// Posted after a link is stashed, on the main queue. `object` is nil: the
    /// observer takes the URL from `take()` so there is exactly one owner of it.
    static let delivered = Notification.Name("app.cqutmux.openLinkDelivered")

    private let lock = NSLock()
    private var pending: URL?

    /// Hands over a URL for the app to open. The newest wins: two taps before
    /// the app is up are two taps on the same thing.
    func deliver(_ url: URL) {
        lock.lock()
        pending = url
        lock.unlock()
        // Announced *after* the stash is written, so an observer that runs
        // immediately still finds the URL. Main queue because the delegate
        // callback need not be on it and the observer is a view.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: OpenLink.delivered, object: nil)
        }
    }

    /// Takes the pending URL, if any, leaving none behind.
    func take() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        defer { pending = nil }
        return pending
    }
}

/// The host the app was last pointed at, so a cold launch can go back to it.
///
/// Keyed by address rather than by the saved host's id, for the same reason
/// `LastSessionStore` is: re-pairing a host mints a new id, and a record that
/// forgot the host because it had been re-added would be a reconnect that never
/// worked after the one operation a user performs when a host breaks.
enum LastHost {
    static let key = "cqutmux.lastHost"

    static func identifier(for host: Host) -> String { "\(host.hostname):\(host.port)" }

    static func record(_ host: Host, in defaults: UserDefaults = .standard) {
        defaults.set(identifier(for: host), forKey: key)
    }

    static func recorded(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }
}

/// What a cold launch should do about the host it was last pointed at.
///
/// Moshi reconnects the last host on launch. Ours did it only under
/// `CQUT_DEV_HOST`, so an ordinary launch came up connected to nothing: the
/// Inbox, the Live Activity and every approval waited on a host the user had to
/// reselect by hand, and the first frame after launch was the same either way.
enum LaunchConnect {
    enum Action: Equatable {
        case connect(Host)
        case none
    }

    /// The one place the decision is made.
    ///
    /// A link suppresses the reconnect **only when it names a destination of its
    /// own** — a session or a host. That is the case where the link *is* the
    /// instruction about where to be and a reconnect to the last host would
    /// fight the navigation the link sets up.
    ///
    /// The link kinds that only name a *screen* — `.notification`, `.inbox`,
    /// `.usage`, `.theme` — are the opposite case, and getting this backwards is
    /// the bug this rule was rewritten for. A notification tap launches with
    /// `cqutmux://notification`, which names no host; suppressing the reconnect
    /// on it lands the user on an Inbox that has nothing to show, because the
    /// Inbox renders its feed off `connection.client` and there is no client.
    /// The tap that was supposed to deliver an approval delivers an empty
    /// screen. Those links need the reconnect precisely *because* they name no
    /// host: it is what gives the screen they open something to draw.
    ///
    /// A recorded host that is no longer saved resolves to `.none` rather than
    /// connecting to something the user deleted. There is deliberately no "the
    /// only saved host" fallback: that would connect on the first launch after
    /// pairing, before the user has been anywhere, and Moshi's rule here is the
    /// *last* host, not any host.
    static func action(hosts: [Host], recorded: String?, launching link: URL?) -> Action {
        if let link, let target = try? DeepLink.parse(link).get().target, target.namesDestination {
            return .none
        }
        guard let recorded else { return .none }
        guard let host = hosts.first(where: { LastHost.identifier(for: $0) == recorded }) else {
            return .none
        }
        return .connect(host)
    }
}
