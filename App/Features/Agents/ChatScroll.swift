import CoreGraphics

/// Whether the conversation should keep following the newest turn.
///
/// Moshi's Chat View: "If you scroll up, a jump-to-bottom control appears so
/// new output does not pull you away from what you are reading." That is two
/// behaviours with one shared trigger, and the trigger is the part that fails
/// quietly — get it wrong and either the view keeps yanking the reader to the
/// bottom while they are reading back, or it stops following while they are
/// sitting at the bottom waiting for the answer to arrive.
///
/// So the rule is a pure function of one number: how far the content's end is
/// below the visible bottom, in points. At the bottom that distance is ~zero;
/// scrolling up makes it grow. Foundation/CoreGraphics-only, so a check can
/// drive it without a simulator — the threshold is not something a screenshot
/// can be read for.
enum ChatScroll {
    /// How far past the bottom the reader may drift and still be "following".
    ///
    /// Not zero: a rubber-band overscroll and the last line's descender both
    /// put the distance a hair above zero at the true bottom, and a reader who
    /// nudged nothing would otherwise silently stop following.
    static let followThreshold: CGFloat = 40

    /// Whether a scroll position that leaves `distanceToBottom` points of
    /// content below the fold should keep auto-scrolling to the newest turn.
    ///
    /// A negative distance (overscrolled past the end by a bounce) follows too:
    /// it is beyond the bottom, not above it.
    static func follows(afterScrollDistance distanceToBottom: CGFloat) -> Bool {
        distanceToBottom < followThreshold
    }
}