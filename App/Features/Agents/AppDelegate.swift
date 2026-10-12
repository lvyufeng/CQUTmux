import Foundation
import UIKit
import UserNotifications

/// Bridges the two things SwiftUI has no hook for: the APNs device token, and
/// notification responses that arrive while the app is backgrounded or not
/// running at all.
///
/// A SwiftUI `App` cannot be a `UIApplicationDelegate`, so the two are joined
/// with `@UIApplicationDelegateAdaptor` in `CQUTmuxApp`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in PushCoordinator.shared.set(token: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected without a push-capable provisioning profile. Not surfaced:
        // the local-notification path covers the same approvals, so a failure
        // here is not something the user can act on.
        #if DEBUG
        print("[push] remote registration failed: \(error.localizedDescription)")
        #endif
    }

    /// A notification tapped while the app runs, or answered from its buttons.
    /// `completionHandler` must be called exactly once or the system assumes
    /// the response was dropped and re-delivers next launch.
    ///
    /// What the response *means* is decided in `NotificationRouting`, so the
    /// plain-tap case — which the old switch fell through and did nothing with,
    /// leaving the app on whatever tab it was last on — is checked without a
    /// device.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let route = NotificationRouting.route(
            actionIdentifier: response.actionIdentifier, userInfo: info
        )
        // A tap opens the app itself; the link is delivered through
        // `onOpenURL` and routes to the Inbox. Set before the hop to the main
        // actor so a launch that has not yet built the window still carries it.
        if case .open = route, let url = NotificationRouting.inboxLink {
            OpenLink.shared.deliver(url)
        }
        Task { @MainActor in
            switch route {
            case .decide(let id, let allow):
                PushCoordinator.shared.onRemoteDecision?(id, allow)
            case .open:
                // The same refresh a push arriving in the foreground does: the
                // tap is a statement that the user is looking, and the newest
                // event should be there when the Inbox draws.
                if let id = NotificationRouting.eventId(from: info) {
                    PushCoordinator.shared.onRemoteEvent?(id)
                }
            case .none:
                break
            }
            completionHandler()
        }
    }

    /// Show pushes while the app is in the foreground too, and set the category
    /// the gateway did not have to know about so the buttons appear.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let info = notification.request.content.userInfo
        // A paused device still receives the push — the gateway has no way to
        // know — so the suppression has to happen here, at the last point
        // before it would be shown. The local-banner path consults the same
        // rule (`NotificationRouting.mayPresent`), because a pause that
        // silenced one and not the other would be a switch that appears broken.
        guard NotificationRouting.mayPresent(isPaused: PushCoordinator.shared.isPaused) else {
            completionHandler([])
            return
        }
        if let id = NotificationRouting.eventId(from: info) {
            Task { @MainActor in PushCoordinator.shared.onRemoteEvent?(id) }
        }
        completionHandler([.banner, .sound, .list])
    }
}