import Foundation
import UserNotifications

/// Tracks which gateway events the user has already been told about, so the
/// feed can deliver a local notification exactly once per event even as the
/// app polls it repeatedly.
struct NotificationLedger {
    private var seen: Set<Int> = []

    /// Returns the events that are new to the ledger. The first call seeds it
    /// silently: the poller's opening page is history, not news.
    mutating func fresh(from events: [AgentEvent], isFirstLoad: Bool) -> [AgentEvent] {
        defer { seen.formUnion(events.map(\.id)) }
        guard !isFirstLoad else { return [] }
        return events.filter { !seen.contains($0.id) }
    }
}

enum ApprovalNotifier {
    /// True once the user has granted permission; notifications are a nicety,
    /// so a denial is recorded and never asked about again.
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Posts one notification per new pending approval.
    static func notify(_ events: [AgentEvent], hostName: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional else { return }

        for event in events where event.isPending {
            let content = UNMutableNotificationContent()
            content.title = "\(event.sourceLabel) needs approval"
            content.body = event.title.isEmpty ? hostName : "\(event.title) — \(hostName)"
            content.sound = .default
            content.userInfo = ["eventId": event.id]

            let request = UNNotificationRequest(
                identifier: "cqutmux.approval.\(event.id)",
                content: content,
                trigger: nil // deliver immediately
            )
            try? await center.add(request)
        }
    }
}