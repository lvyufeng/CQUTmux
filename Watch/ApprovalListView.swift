import SwiftUI
import WatchConnectivity
import WidgetKit

/// The watch's whole job: show what the agent is waiting on and let the wearer
/// answer without reaching for the phone.
///
/// There is no connection state to show here. The watch cannot open an SSH
/// session, so if the list is empty that may mean either "nothing pending" or
/// "the phone hasn't pushed yet" — the empty state says both, rather than
/// implying an all-clear it can't actually vouch for.
///
/// NOT wrapped in its own `NavigationStack`: `WatchRootView` owns the one
/// stack and switches between this and the usage screen inside it. A second
/// stack here would nest, and the inner title would win — which is exactly
/// what a first attempt at this did.
struct ApprovalListView: View {
    @State private var link = WatchLink.shared
    @State private var sent: [Int: Bool] = [:]

    private var items: [WatchPayload.Snapshot.Item] { link.items }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "Nothing pending",
                    systemImage: "checkmark.circle",
                    description: Text("Open CQUTmux on your iPhone and connect to a host.")
                )
            } else {
                List(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.source)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item.title)
                            .font(.headline)
                            .lineLimit(3)
                        if !item.body.isEmpty {
                            Text(item.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }

                        if let allow = sent[item.id] {
                            Label(
                                allow ? "Approved" : "Denied",
                                systemImage: allow ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .font(.caption2)
                            .foregroundStyle(allow ? .green : .orange)
                        } else if item.isQuestion {
                            // An agent waiting on a choice is waiting just
                            // as much as one waiting on permission, and
                            // this is the case where reaching for the phone
                            // is most annoying.
                            VStack(spacing: 4) {
                                ForEach(item.options) { option in
                                    Button(option.label) { answer(item, option.value) }
                                        .buttonStyle(.bordered)
                                }
                            }
                        } else {
                            HStack {
                                Button(role: .destructive) { decide(item, allow: false) } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)

                                Spacer()

                                Button { decide(item, allow: true) } label: {
                                    Image(systemName: "checkmark")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Approvals")
        .onAppear { WatchLink.shared.start() }
        #if DEBUG
        // The watch simulator renders but cannot be tapped from the command
        // line, so the decision path has no way to run in an automated check.
        // This stands in for the finger: it sends exactly what the Allow button
        // sends, through the same `decide`-to-`WatchLink.send` route, once the
        // list is non-empty. It is DEBUG-only and gated on an explicit env var,
        // so it can never fire in a build a wearer is using.
        .onChange(of: items) { _, new in
            guard let id = Self.autodecideTarget,
                  let item = new.first(where: { $0.id == id }) else { return }
            decide(item, allow: ProcessInfo.processInfo.environment["CQUT_DEV_WATCH_DECISION"] != "deny")
        }
        #endif
    }

    #if DEBUG
    /// The approval id a dev launch wants answered, or nil in a normal run.
    private static var autodecideTarget: Int? {
        ProcessInfo.processInfo.environment["CQUT_DEV_WATCH_APPROVE"].flatMap(Int.init)
    }
    #endif

    private func decide(_ item: WatchPayload.Snapshot.Item, allow: Bool) {
        sent[item.id] = allow
        WatchLink.shared.send(.init(id: item.id, allow: allow))
    }

    /// A question is answered as "approved" plus the chosen value: the
    /// allow/deny field stays meaningful for anything that reads a decision
    /// without knowing about options.
    private func answer(_ item: WatchPayload.Snapshot.Item, _ value: String) {
        sent[item.id] = true
        WatchLink.shared.send(.init(id: item.id, allow: true, answer: value))
    }
}

/// Holds the `WCSession` on the watch side. Kept separate from the view so the
/// session lives as long as the app rather than being rebuilt with the view.
@Observable
final class WatchLink: NSObject {
    static let shared = WatchLink()

    private(set) var items: [WatchPayload.Snapshot.Item] = []
    /// The latest usage rings, or nil if the phone has not pushed any yet.
    /// Kept as an optional rather than an empty array so "no data" and "zero
    /// percent" stay distinguishable — an empty ring reads as a measured 0%.
    private(set) var usage: WatchPayload.Usage?
    @ObservationIgnored var onChange: (([WatchPayload.Snapshot.Item]) -> Void)?

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func start() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Re-reads both contexts from the session. Called once at activation, so
    /// a watch that was asleep through a push still shows the last value the
    /// phone sent rather than an empty screen.
    private func reload() {
        guard let session else { return }
        let context = session.receivedApplicationContext
        apply(context[WatchPayload.pendingKey])
        applyUsage(context[WatchPayload.usageKey])
    }

    func send(_ decision: WatchPayload.Decision) {
        guard let session, let data = WatchPayload.encode(decision) else { return }
        // A decision is small and sent while the wrist is up, so the immediate
        // path is right; the queued transfer is the fallback if the phone is
        // out of range right now.
        if session.isReachable {
            session.sendMessage([WatchPayload.decisionKey: data], replyHandler: nil)
        } else {
            session.transferUserInfo([WatchPayload.decisionKey: data])
        }
    }
}

extension WatchLink: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async { self.reload() }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.apply(applicationContext[WatchPayload.pendingKey])
            self.applyUsage(applicationContext[WatchPayload.usageKey])
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        // Queued decisions arrive as user info on the phone, not here, but the
        // protocol is symmetric and harmless to accept.
        DispatchQueue.main.async { self.apply(userInfo[WatchPayload.pendingKey]) }
    }

    private func apply(_ payload: Any?) {
        guard let data = payload as? Data,
              let snapshot = WatchPayload.decode(WatchPayload.Snapshot.self, from: data)
        else { return }
        items = snapshot.items
        onChange?(snapshot.items)
    }

    private func applyUsage(_ payload: Any?) {
        guard let data = payload as? Data,
              let decoded = WatchPayload.decode(WatchPayload.Usage.self, from: data)
        else { return }
        usage = decoded
        // Mirror it into the App Group so the complication extension can read
        // it: that extension is a separate process with its own container and
        // no access to the WatchConnectivity context. A copy rather than the
        // only store, so the app keeps working when the App Group entitlement
        // is absent.
        if let defaults = WatchPayload.sharedDefaults, let encoded = WatchPayload.encode(decoded) {
            defaults.set(encoded, forKey: WatchPayload.sharedUsageKey)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}