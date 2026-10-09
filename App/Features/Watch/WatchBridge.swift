import Foundation
import WatchConnectivity
import Observation

/// Mirrors the phone's pending approvals onto a paired Apple Watch and applies
/// the decisions that come back.
///
/// The watch cannot reach the host on its own — there is no SSH session there —
/// so it never talks to the gateway directly. The phone pushes a snapshot of
/// what is pending; the watch answers with allow/deny for one id, and this
/// object turns that into the same `HookClient.resolve` the Inbox uses.
@Observable
final class WatchBridge: NSObject {
    private(set) var activated = false
    private(set) var lastTransfer: String?

    /// Set by the app once a host connection exists. Called on the main queue.
    @ObservationIgnored var onDecision: ((Int, Bool) -> Void)?
    /// A question answered by choosing an option, separate from allow/deny.
    @ObservationIgnored var onAnswer: ((Int, String) -> Void)?
    /// Supplies the current pending approvals to push to the watch.
    @ObservationIgnored var pendingSnapshot: (() -> WatchPayload.Snapshot)?
    @ObservationIgnored var onNeedSnapshot: (() -> Void)?

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Pushes the current pending set. Called whenever the Inbox changes.
    func publish(_ snapshot: WatchPayload.Snapshot) {
        guard let session, session.activationState == .activated else { return }
        guard let data = WatchPayload.encode(snapshot) else { return }
        do {
            // applicationContext is the right mailbox: it holds only the latest
            // value, survives the watch being asleep, and delivers on wake —
            // which is exactly the semantics of "here is what is pending now".
            try session.updateApplicationContext([WatchPayload.pendingKey: data])
            lastTransfer = "sent \(snapshot.items.count)"
        } catch {
            lastTransfer = "push failed: \(error.localizedDescription)"
        }
    }
}

extension WatchBridge: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.activated = activationState == .activated
            if self.activated { self.onNeedSnapshot?() }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // A watch can be swapped for another; re-activate for the new one.
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[WatchPayload.decisionKey] as? Data,
              let decision = WatchPayload.decode(WatchPayload.Decision.self, from: data)
        else { return }
        DispatchQueue.main.async {
            if let answer = decision.answer {
                self.onAnswer?(decision.id, answer)
            } else {
                self.onDecision?(decision.id, decision.allow)
            }
        }
    }
}