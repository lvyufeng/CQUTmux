import UIKit
import UserNotifications

/// Holds the APNs device token and the callbacks that hang off it.
///
/// Remote push is the one part of the notification story that cannot be
/// exercised locally: APNs needs a provisioning profile with the push
/// entitlement and a signing key, and neither exists without a developer
/// account. The code below is the whole client half — register, receive the
/// token, hand it to the gateway, and answer an approval from the lock screen
/// — so the moment a key and profile do exist it works, and until then the
/// local-notification path already covers the same approvals while the app is
/// running.
///
/// The gateway holds the token; it is what talks to APNs. That is deliberate:
/// the phone never needs the signing key, and the host already knows when an
/// approval appears.
final class PushCoordinator: NSObject, @unchecked Sendable {
    static let shared = PushCoordinator()

    /// Categories let a notification carry Allow/Deny buttons instead of
    /// making the user open the app to answer.
    enum Category {
        static let approval = "CQUT_APPROVAL"
    }

    enum Action {
        static let allow = "CQUT_ALLOW"
        static let deny = "CQUT_DENY"
    }

    /// Set by the app once a host connection exists. The token is held until
    /// then, because there is nowhere to send it before that. Like the watch
    /// bridge's callbacks, these are read and written only on the main queue.
    private(set) var deviceToken: String?

    /// Whether the app is accepting pushes. Pausing keeps the token and only
    /// quiets delivery on this device, which is what Moshi's switch does — the
    /// alternative (unregistering) would mean the user has to re-authorise to
    /// resume.
    ///
    /// The switch is enforced here rather than server-side because the gateway
    /// sends to every registered device; a "paused" device that still received
    /// banners would make the setting a lie.
    var isPaused: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pausedKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.pausedKey)
            // Delivery is decided in `received` and `willPresent`, so pausing
            // also has to clear what is already on the lock screen — otherwise
            // the switch quiets the next push and leaves this one sitting there.
            if newValue {
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            }
        }
    }

    private static let pausedKey = "cqutmux.push.paused"
    /// Called with (eventId, allow) when the user answers from a notification.
    var onRemoteDecision: ((Int, Bool) -> Void)?
    /// Called when a push arrives, so the feed can refresh immediately rather
    /// than waiting for the next poll.
    var onRemoteEvent: ((Int) -> Void)?
    /// Hands the token to the gateway. Set alongside `onRemoteDecision`.
    var onToken: ((String) -> Void)?

    func register() {
        UNUserNotificationCenter.current().setNotificationCategories(Self.categories())
        // registerForRemoteNotifications itself decides whether the device can
        // receive pushes; the delegate callbacks below are what report it
        // either way. Called on the main actor because UIApplication is.
        UIApplication.shared.registerForRemoteNotifications()
    }

    private static func categories() -> Set<UNNotificationCategory> {
        let allow = UNNotificationAction(
            identifier: Action.allow, title: "Allow", options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: Action.deny, title: "Deny", options: [.destructive, .authenticationRequired]
        )
        return [UNNotificationCategory(
            identifier: Category.approval,
            actions: [allow, deny],
            intentIdentifiers: [],
            options: []
        )]
    }

    /// A push carrying the new event's id. The id is all that travels: the
    /// body the user reads comes from the notification payload, and the app
    /// refetches the event itself, so a stale push can never invent an
    /// approval that the gateway does not have.
    func received(userInfo: [AnyHashable: Any], decision: (Int, Bool)?) {
        let id = (userInfo["eventId"] as? Int)
            ?? (userInfo["eventId"] as? String).flatMap(Int.init)
        guard let id else { return }
        if let decision {
            onRemoteDecision?(id, decision.1)
        } else {
            onRemoteEvent?(id)
        }
    }

    func set(token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        onToken?(hex)
    }
}