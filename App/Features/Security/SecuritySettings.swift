import Foundation
import LocalAuthentication
import Observation

/// The security switches the settings screen offers.
///
/// Only the ones that change behaviour are here. Moshi's list also has an
/// iCloud-sync toggle for hosts and credentials; syncing would mean moving the
/// host list from a local file into a key-value store and deciding what is safe
/// to put in iCloud, and a switch that syncs nothing is worse than no switch.
/// So it is absent rather than inert.
@Observable
final class SecuritySettings {
    private enum Key {
        static let unlockOnResume = "cqutmux.security.unlockOnResume"
        static let clipboardRead = "cqutmux.security.clipboardRead"
    }

    /// Whether a program running on the host may read this device's clipboard
    /// through OSC 52.
    ///
    /// Off by default, and the default is the whole point. OSC 52 read is a
    /// request that arrives *from the remote side* — an `ssh` session, a tmux,
    /// an agent — with no gesture from the user on this end. Allowing it means
    /// anything that ends up running in a session can ask for whatever was last
    /// copied: a password, a 2FA code, a private message. The write direction
    /// has none of that risk, which is why it is allowed and this is not.
    ///
    /// A biometric prompt per read would be better than a blanket switch, but
    /// SwiftTerm's `clipboardRead` is a synchronous `Data? -> Data?` call with
    /// no place to await a Face ID sheet. Rather than a prompt that cannot
    /// exist, this is a deliberate, disclosed, off-by-default permission — and
    /// the screen says what it costs.
    var allowsClipboardRead: Bool {
        didSet { defaults.set(allowsClipboardRead, forKey: Key.clipboardRead) }
    }

    /// Ask for biometrics when the app comes back to the foreground.
    ///
    /// Stored as `Bool?` semantics — absent means "not chosen yet" — because the
    /// default depends on the device: offering a Face ID prompt on a phone with
    /// nothing enrolled would lock the user out of their own app.
    var unlockOnResume: Bool {
        didSet { UserDefaults.standard.set(unlockOnResume, forKey: Key.unlockOnResume) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Key.unlockOnResume) as? Bool
        // On by default wherever biometrics are enrolled, which is the setting
        // that matches what Moshi describes and what a user protecting SSH keys
        // would expect. On a device with nothing enrolled it defaults off and
        // the toggle says why it cannot be turned on.
        unlockOnResume = stored ?? Biometrics.isEnrolled
        // Plain `bool(forKey:)` is right here: absent means off, and off is the
        // safe answer. Unlike the case above there is no device-dependent
        // default to preserve.
        allowsClipboardRead = defaults.bool(forKey: Key.clipboardRead)
    }

    /// Whether the device can do this at all. Drives whether the toggle is
    /// usable and what the footer says.
    var isAvailable: Bool { Biometrics.isEnrolled }

    /// The lock screen shown while the app is hidden behind the prompt.
    @Observable
    final class Gate {
        private(set) var isLocked = false
        private(set) var problem: String?

        /// Prompts, if the setting asks for it and the app was away long enough
        /// to be worth it. Called when the app returns to the foreground.
        @MainActor
        func lockIfNeeded(settings: SecuritySettings) {
            guard settings.unlockOnResume, settings.isAvailable, !isLocked else { return }
            isLocked = true
            Task { await unlock(reason: "Unlock CQUTmux") }
        }

        @MainActor
        func unlock(reason: String) async {
            guard Biometrics.isEnrolled else {
                isLocked = false
                return
            }
            let context = LAContext()
            do {
                let ok = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: reason
                )
                // A failed read is not an error to report: the sheet stays up
                // and the user tries again, which is what the prompt's own
                // "Try Again" would do.
                if ok { isLocked = false }
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Whether the device has biometrics enrolled, and which kind.
enum Biometrics {
    static var kind: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    /// Enrolled and usable. `canEvaluatePolicy` is the only honest test: a
    /// device can have a sensor and no enrolled prints, in which case every
    /// prompt fails immediately.
    static var isEnrolled: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static var label: String {
        switch kind {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: "Biometrics"
        }
    }
}