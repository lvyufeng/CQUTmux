import UIKit

/// A two-finger directional sweep that reports which way the drag went.
///
/// UIKit has no equivalent, which is why this exists. `UISwipeGestureRecognizer`
/// cannot require exactly two touches while also telling the handler which
/// direction the drag took *and* refusing a diagonal; and a
/// `UIPanGestureRecognizer` enters `.began` on the first movement, so a
/// recogniser waiting on it (the mouse-wheel pan does) never gets the chance to
/// run when this one turns out not to be a sweep.
///
/// This one stays out of the way until the drag has actually resolved: it ends
/// having committed to a direction, or it fails, and failing is what lets
/// whatever required it to fail proceed.
///
/// The direction convention is "positive is next": a rightward horizontal drag
/// and a downward vertical drag both mean forwards, which is the direction the
/// content would move if the pane advanced.
final class UISweepGesture: UIGestureRecognizer {
    enum Axis { case horizontal, vertical }
    enum Direction { case positive, negative }

    var axis: Axis = .horizontal

    /// How many touches the sweep needs.
    ///
    /// Checked here rather than through `minimumNumberOfTouches`, which only
    /// `UIPanGestureRecognizer` has. Exactly this many — one is a drag the
    /// terminal owns, three is a different gesture.
    var requiredTouches = 2

    /// How far along the axis the drag must travel before it counts, in points.
    /// Roughly a thumb's travel, and far enough that a tap with a wobble in it
    /// does not switch panes.
    static let minimumTravel: CGFloat = 44

    /// How much more the drag must travel along its axis than across it. A
    /// diagonal has to resolve to one axis or the gesture is ambiguous, and
    /// guessing would send a pane switch where the user meant a tab switch.
    static let dominance: CGFloat = 1.4

    /// Set once the drag has resolved. Nil means this was never a sweep.
    private(set) var direction: Direction?

    /// Whether this sweep has anywhere to send what it detects.
    ///
    /// A recogniser that required this one to fail — the mouse-wheel pan does —
    /// only gets to run if this one actually *fails*, and a sweep that ended
    /// having recognised a gesture it had no command for would suppress the
    /// wheel while sending nothing itself. So the check is made here, up front,
    /// rather than in the handler: no multiplexer (or the setting off) means
    /// this fails immediately and the two-finger drag reaches the scrollback
    /// exactly as it did before this gesture existed.
    var isAvailable = false

    private var origin = CGPoint.zero
    private var along: CGFloat = 0
    private var across: CGFloat = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard isAvailable else {
            state = .failed
            return
        }
        // A third finger makes this a different gesture than the one asked for.
        // Refusing is better than picking two of the three to honour.
        guard numberOfTouches <= requiredTouches else {
            state = .failed
            return
        }
        // The origin is reset on every touch-down, so the second finger of the
        // pair is what the travel is measured from — the first finger may have
        // been down long enough to drift.
        direction = nil
        along = 0
        across = 0
        origin = touches.first?.location(in: view) ?? .zero
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        // Only the intended number of fingers counts. One finger down is the
        // terminal's own drag; treating it as a sweep would make ordinary
        // selection impossible.
        guard numberOfTouches == requiredTouches, let touch = touches.first else { return }
        let point = touch.location(in: view)
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        switch axis {
        case .horizontal:
            along = dx
            across = dy
        case .vertical:
            along = dy
            across = dx
        }
        if abs(along) >= Self.minimumTravel, abs(along) > abs(across) * Self.dominance {
            direction = along > 0 ? .positive : .negative
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        // The decision is made here rather than mid-drag: a direction that was
        // set and then un-set by the finger wandering back would be a pane
        // switch the user never asked for.
        state = direction == nil ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .cancelled
    }

    override func reset() {
        super.reset()
        direction = nil
        along = 0
        across = 0
    }
}