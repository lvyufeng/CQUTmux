import SwiftUI
import WatchConnectivity

/// The watch's whole job: show what the agent is waiting on and let the wearer
/// answer without reaching for the phone.
///
/// There is no connection state to show here. The watch cannot open an SSH
/// session, so if the list is empty that may mean either "nothing pending" or
/// "the phone hasn't pushed yet" — the empty state says both, rather than
/// implying an all-clear it can't actually vouch for.
struct ApprovalListView: View {
    @State private var link = WatchLink.shared
    @State private var sent: [Int: Bool] = [:]

    private var items: [WatchPayload.Snapshot.Item] { link.items }

    var body: some View {
        NavigationStack {
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
        }
        .onAppear { WatchLink.shared.start() }
    }

    private func decide(_ item: WatchPayload.Snapshot.Item, allow: Bool) {
        sent[item.id] = allow
        WatchLink.shared.send(.init(id: item.id, allow: allow))
    }
}

/// Holds the `WCSession` on the watch side. Kept separate from the view so the
/// session lives as long as the app rather than being rebuilt with the view.
@Observable
final class WatchLink: NSObject {
    static let shared = WatchLink()

    private(set) var items: [WatchPayload.Snapshot.Item] = []
    @ObservationIgnored var onChange: (([WatchPayload.Snapshot.Item]) -> Void)?

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func start() {
        guard let session else { return }
        session.delegate = self
        session.activate()
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
        DispatchQueue.main.async {
            let payload = session.receivedApplicationContext[WatchPayload.pendingKey]
            self.apply(payload)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.apply(applicationContext[WatchPayload.pendingKey]) }
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
}