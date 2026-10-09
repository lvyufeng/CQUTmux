import Foundation
import Observation

/// Whether the custom keys are live, and whether they are armed to lock.
///
/// The accessory bar is a row of buttons that sit directly above the terminal,
/// and a phone held one-handed puts a thumb on it by accident. Every accidental
/// tap sends real bytes to a real shell — a control-C, a stray `Escape` out of
/// an editor — so a session where the bar is mostly typed past wants a way to
/// stop listening to the bar without giving up the screen space it occupies.
///
/// The gesture is a double tap on the Custom Keys button. That button is the
/// head of the group it guards, so the thing you double-tap is the thing that
/// goes quiet, and no new control has to be fit into a bar that has no room.
///
/// The lock is deliberately not persisted: a locked bar that survives a launch
/// reads as a broken bar, and the user who locked it last Tuesday will not
/// remember doing it.
@Observable
final class ShortcutLock {
    /// Whether taps on the custom keys do anything.
    private(set) var isLocked = false

    /// When the lock button was last tapped, so a second tap within the window
    /// counts as a double tap. Held here rather than in the view because the
    /// bar is rebuilt on every settings change and would forget it — the same
    /// problem the Ctrl lock has.
    @ObservationIgnored private var lastTap = Date.distantPast

    /// How long two taps may be apart and still be one gesture. Long enough
    /// that a deliberate double tap is not rejected for being slow, short
    /// enough that two taps meant as separate presses are not fused.
    static let doubleTapWindow: TimeInterval = 0.4

    /// Registers a tap on the lock button.
    ///
    /// - Returns: whether the tap was *consumed* by the lock — that is, whether
    ///   the caller should hold off on the button's own action. A tap that locks
    ///   must not also do the button's job, or the gesture that stops the bar
    ///   from acting is itself an action.
    ///
    /// While locked, any tap reopens the bar rather than requiring the double
    /// tap again. The double tap is how you *stop* the bar listening, and asking
    /// for it a second time to undo is the kind of symmetry that reads well and
    /// traps anyone who taps once and finds nothing happening.
    @discardableResult
    func tap(at now: Date = Date()) -> Bool {
        if isLocked {
            isLocked = false
            lastTap = .distantPast
            return true
        }
        let isDouble = now.timeIntervalSince(lastTap) <= Self.doubleTapWindow
        lastTap = isDouble ? .distantPast : now
        guard isDouble else { return false }
        isLocked = true
        return true
    }

    /// Unlocks without a double tap, for anything that must not be swallowed —
    /// leaving the screen, or the user asking for the bar back from Settings.
    func unlock() { isLocked = false }
}