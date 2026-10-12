import Foundation
import UserNotifications

// What a launch and a notification response do, checked without a simulator.
//
// Every rule here fails silently. A notification tap that routes nowhere looks
// exactly like a tap the user did not make, and a cold launch that reconnects
// nothing looks exactly like a feature that was never built — neither throws,
// neither logs, and in the first case the approval the notification was about
// simply waits behind a tab nobody opened. That is the same class of failure
// the Inbox rules exist to prevent, so the rules live in `LaunchRouting.swift`
// and are driven here with constructed hosts and payloads.
//
// The three the app delegate and the shell call are all in that file, so this
// binary is also a compile-time guard: a SwiftUI or UIKit type creeping into
// them stops this compiling, which is the honest outcome — they can no longer
// be checked apart from the view.

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

func host(_ hostname: String, port: Int = 22, name: String = "") -> Host {
    var value = Host()
    value.hostname = hostname
    value.port = port
    value.name = name
    value.username = "someone"
    return value
}

// MARK: - A tap on a notification opens the Inbox

// The case this gap is about. A tap on the body carries the system's own
// identifier, not one of ours, and it used to fall through the old switch and
// do nothing at all.
check(NotificationRouting.route(
        actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: ["eventId": 7]
      ) == .open,
      "a tap on a notification's body asks to open the Inbox")

// Even for a tap that names the event it was about. The Inbox is the
// destination either way, and an id nothing reads would be a claim that this
// routes more finely than it does.
check(NotificationRouting.route(
        actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: [:]
      ) == .open,
      "a tap opens the Inbox even when the payload names no event")

// MARK: - A button answers the event it names

check(NotificationRouting.route(
        actionIdentifier: NotificationAction.allow, userInfo: ["eventId": 12]
      ) == .decide(eventId: 12, allow: true),
      "Allow answers the event the notification names")

check(NotificationRouting.route(
        actionIdentifier: NotificationAction.deny, userInfo: ["eventId": 12]
      ) == .decide(eventId: 12, allow: false),
      "Deny answers the event the notification names")

// The gateway holds the id as a JSON number, but `userInfo` round-trips through
// `NSNumber` and a hand-made payload can carry a string — the same tolerance
// `PushCoordinator.received` has.
check(NotificationRouting.route(
        actionIdentifier: NotificationAction.allow, userInfo: ["eventId": "12"]
      ) == .decide(eventId: 12, allow: true),
      "an event id that arrived as a string still resolves")

// A button on a notification that names no event resolves to nothing rather
// than to a decision. The old code passed a placeholder id of 0 here, which is
// a decision about an event the host does not have.
check(NotificationRouting.route(
        actionIdentifier: NotificationAction.allow, userInfo: [:]
      ) == .none,
      "Allow on a notification with no event id answers nothing")

// The system's dismissal carries its own identifier and must not be read as a
// tap: dismissing a banner is not opening the Inbox.
check(NotificationRouting.route(
        actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: ["eventId": 3]
      ) == .none,
      "a dismissed notification is not a tap")

// An action a future build registers that this one does not know — and the
// placeholder `NotificationRouting`'s own tests would otherwise never cover.
check(NotificationRouting.route(
        actionIdentifier: "CQUT_SOMETHING_NEW", userInfo: ["eventId": 3]
      ) == .none,
      "an unrecognised action is handled rather than obeyed")

// MARK: - The tap's link is the one the Inbox already honours

// The route is a link rather than a direct tab change, so a tap takes the same
// `handle(url)` path a pasted link does. Parsed rather than string-compared:
// what matters is that the app understands it, not how it is spelled.
if let url = NotificationRouting.inboxLink,
   case .success(let link) = DeepLink.parse(url) {
    check(link.target == .notification, "a tap's link parses to the notification route")
    check(link.session == nil, "the tap's link carries no session for the terminal to attach")
} else {
    check(false, "a tap's link parses to the notification route")
    check(false, "the tap's link carries no session for the terminal to attach")
}

// The notification route is its own target, not the Live Activity's `inbox`:
// they obey different rules (see `DeepLink.Target.notification`), and a parser
// that folded one into the other would make the difference unrepresentable.
if let url = URL(string: "cqutmux://notification"),
   case .success(let link) = DeepLink.parse(url) {
    check(link.target == .notification, "cqutmux://notification is its own target")
} else {
    check(false, "cqutmux://notification is its own target")
}
if let url = URL(string: "cqutmux://inbox"),
   case .success(let link) = DeepLink.parse(url) {
    check(link.target == .inbox, "cqutmux://inbox is not the notification route")
} else {
    check(false, "cqutmux://inbox is not the notification route")
}

// MARK: - One pause rule, read by both banner paths

check(NotificationRouting.mayPresent(isPaused: false),
      "a running app may present while not paused")
check(!NotificationRouting.mayPresent(isPaused: true),
      "a paused app presents nothing")

/// A pending approval and a notice that needs nothing, the two shapes the local
/// path is handed.
func event(_ id: Int, pending: Bool) -> AgentEvent {
    var value = AgentEvent(
        id: id, at: "2026-10-12T00:00:00Z", source: "claude-code",
        kind: pending ? .approval : .notice, category: nil,
        title: "Bash", body: "ls", decision: nil, answer: nil, data: nil
    )
    if !pending { value.decision = "allow" }
    return value
}

let mix = [event(1, pending: true), event(2, pending: false), event(3, pending: true)]

// The local banner path's whole decision, in one function, so the pause cannot
// be forgotten at the call site the way it was: `notify(_:hostName:)` used to
// filter on `isPending` alone and post while paused.
check(NotificationRouting.localNotifications(for: mix, isPaused: false).map(\.id) == [1, 3],
      "local banners are the pending events, in order")
check(NotificationRouting.localNotifications(for: mix, isPaused: true).isEmpty,
      "pausing suppresses local banners, not only pushes")

// The remote path reads the same rule. This is the assertion that keeps the two
// from drifting apart: if `mayPresent` ever stops being what `localNotifications`
// consults, the pair above and this one cannot both hold.
check(
    NotificationRouting.localNotifications(for: mix, isPaused: true).isEmpty
        == !NotificationRouting.mayPresent(isPaused: true),
    "the local path and the remote path agree about the pause"
)

// MARK: - A cold launch reconnects the host last used

let first = host("alpha.example", port: 22)
let second = host("beta.example", port: 2222)

check(LaunchConnect.action(hosts: [first, second], recorded: LastHost.identifier(for: second),
                           launching: nil) == .connect(second),
      "a cold launch reconnects the recorded host")

// The address, not the list's order: the last host may be anywhere in it.
check(LaunchConnect.action(hosts: [second, first], recorded: LastHost.identifier(for: first),
                           launching: nil) == .connect(first),
      "the recorded host is found wherever it sits in the list")

// The port is part of what identifies a host. Two hosts on the same machine on
// different ports are two hosts, and a lookup that dropped the port would
// reconnect to the wrong one.
check(LaunchConnect.action(hosts: [first, host("alpha.example", port: 2022)],
                           recorded: LastHost.identifier(for: first),
                           launching: nil) == .connect(first),
      "the port is part of the host's identity")

// A first launch has recorded nothing, and must not connect to whatever
// happens to be in the list: there is a difference between "the host you were
// last on" and "a host".
check(LaunchConnect.action(hosts: [first], recorded: nil, launching: nil) == .none,
      "a first launch reconnects nothing, even with one host saved")

// A host the user deleted since it was recorded resolves to nothing rather
// than to a lookalike or to the first entry.
check(LaunchConnect.action(hosts: [second], recorded: LastHost.identifier(for: first),
                           launching: nil) == .none,
      "a host that is gone since it was recorded reconnects nothing")

// A link that names a *destination* is the instruction about where to go, and
// it wins. The link may also be one that arrives before any session exists —
// the terminal is about to navigate — and a reconnect underneath it would
// fight that.
check(LaunchConnect.action(hosts: [first], recorded: LastHost.identifier(for: first),
                           launching: URL(string: "cqutmux://tmux?session=work")) == .none,
      "a session link suppresses the reconnect, which would race it")

check(LaunchConnect.action(hosts: [first], recorded: LastHost.identifier(for: first),
                           launching: URL(string: "cqutmux://host?host=alpha.example")) == .none,
      "a host link suppresses the reconnect too")

// A link that names only a *screen* is the opposite case, and this is the bug
// the `namesDestination` split was written for. A notification tap launches
// with `cqutmux://notification`; suppressing the reconnect on it would open the
// Inbox with no connection behind it — an empty Inbox, and the approval the tap
// was about nowhere on screen. Every screen-naming link has to reconnect.
for screen in ["cqutmux://notification", "cqutmux://inbox", "cqutmux://usage"] {
    check(LaunchConnect.action(hosts: [first], recorded: LastHost.identifier(for: first),
                               launching: URL(string: screen)) == .connect(first),
          "a screen link (\(screen)) still reconnects, so the screen has data")
}

// And the classification itself is asked of the target, not restated here: a
// URL that does not parse falls back to reconnecting rather than to a silent
// no-op, since a launch nobody can explain should at least land somewhere.
check(LaunchConnect.action(hosts: [first], recorded: LastHost.identifier(for: first),
                           launching: URL(string: "cqutmux://nonsense")) == .connect(first),
      "an unparseable launch link does not suppress the reconnect")

// A renamed host is the same machine: the address is what identifies it, and
// the name the user typed never enters the lookup. Checked by outcome, since
// the point is precisely that the field is not consulted.
check(LaunchConnect.action(hosts: [host("alpha.example", name: "Renamed")],
                           recorded: LastHost.identifier(for: first),
                           launching: nil) != .none,
      "a renamed host is still recognized by its address")

// MARK: - Recording is what the reconnect reads

// The two halves of the record round trip through a scratch suite, so neither
// can be changed without the other noticing — a reconnect reading a key nobody
// writes is a feature that silently does nothing. `defaults` is injectable for
// exactly this.
let suite = "cqutmux.launch-check.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }

check(LastHost.recorded(in: defaults) == nil, "a fresh install has no recorded host")
LastHost.record(second, in: defaults)
check(LastHost.recorded(in: defaults) == LastHost.identifier(for: second),
      "recording a host stores its address")
LastHost.record(first, in: defaults)
check(LastHost.recorded(in: defaults) == LastHost.identifier(for: first),
      "recording again replaces the host, so the last one is the one kept")
check(LaunchConnect.action(hosts: [first, second], recorded: LastHost.recorded(in: defaults),
                           launching: nil) == .connect(first),
      "the reconnect follows what was recorded")

if failures > 0 {
    print("\nLAUNCH_ROUTING_FAIL  (\(failures) of \(checks) routing checks failed)")
    exit(1)
}
print("\nLAUNCH_ROUTING_PASS  (\(checks) checks)")
