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
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let decision: (Int, Bool)?
        switch response.actionIdentifier {
        case PushCoordinator.Action.allow: decision = (0, true)
        case PushCoordinator.Action.deny: decision = (0, false)
        default: decision = nil
        }
        Task { @MainActor in
            PushCoordinator.shared.received(userInfo: info, decision: decision)
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
        if let id = Self.eventId(from: info) {
            Task { @MainActor in PushCoordinator.shared.onRemoteEvent?(id) }
        }
        completionHandler([.banner, .sound, .list])
    }

    private static func eventId(from info: [AnyHashable: Any]) -> Int? {
        (info["eventId"] as? Int) ?? (info["eventId"] as? String).flatMap(Int.init)
    }
}