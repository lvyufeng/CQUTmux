import Foundation
import UIKit
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

    /// Posts a notification that is not about anything, so the user can see
    /// whether delivery works on this device.
    ///
    /// It carries the same category a real approval does, so the Allow/Deny
    /// buttons appear and can be tried — the part of the path most likely to be
    /// misconfigured and the hardest to check by waiting for a real approval.
    ///
    /// `withImage` attaches a generated image rather than sending plain text.
    /// The gateway's real approvals can carry a screenshot of what needs
    /// approving, so the image path is worth being able to exercise on its own:
    /// an attachment that fails to load (or a payload that is too large) changes
    /// how the banner looks, and the text test would not show it.
    static func sendTest(withImage: Bool = false) async throws {
        let content = UNMutableNotificationContent()
        content.title = withImage ? "Test image notification" : "Test notification"
        content.body = "If you can read this, the app's side of notifications works."
        content.sound = .default
        content.categoryIdentifier = PushCoordinator.Category.approval

        if withImage, let attachment = try? testImageAttachment() {
            content.attachments = [attachment]
        }

        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "cqutmux.test.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
    }

    /// Draws the test image in code rather than shipping one in the asset
    /// catalogue: the only picture this app has is the app icon, which says
    /// nothing about a file attachment, and a generated one keeps the test
    /// self-contained — no bundle lookup to fail, and the same bytes every run.
    ///
    /// The attachment moves through a URL on disk because that is the only shape
    /// `UNNotificationAttachment` accepts; the unique name keeps two rapid taps
    /// from writing the same file while the first notification still reads it.
    private static func testImageAttachment() throws -> UNNotificationAttachment {
        let size = CGSize(width: 320, height: 160)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = "CQUTmux test image"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let bounds = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: CGPoint(x: (size.width - bounds.width) / 2,
                            y: (size.height - bounds.height) / 2),
                withAttributes: attributes
            )
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cqutmux-test-\(UUID().uuidString).png")
        try image.pngData()?.write(to: url)
        return try UNNotificationAttachment(identifier: "cqutmux.test.image", url: url)
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
            content.body = event.displayTitle.isEmpty ? hostName : "\(event.displayTitle) — \(hostName)"
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

    /// Takes the notifications for these approvals off the Lock Screen.
    ///
    /// Called when a decision arrives from the Live Activity's buttons: the
    /// answer is on its way to the host, but the notification for it is still
    /// sitting there asking, and a banner that keeps requesting a decision
    /// already made reads as one that was not registered. The identifier is
    /// built the same way `notify` builds it — the two have to agree or this
    /// removes nothing, which is exactly the silent case.
    static func clear(ids: [Int]) {
        guard !ids.isEmpty else { return }
        let identifiers = ids.map { "cqutmux.approval.\($0)" }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        // Pending as well as delivered: a notification posted while the app was
        // backgrounded may not have fired yet, and removing only what is already
        // on screen would let it appear afterwards — asking about an approval
        // this call just answered.
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}