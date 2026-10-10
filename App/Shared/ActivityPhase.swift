import Foundation

/// What a Live Activity is currently about.
///
/// The activity used to know one thing — how many approvals were pending — and
/// ended the moment none were, so a "task complete" or "tool running" event
/// could never surface and a session's ending was indistinguishable from the
/// app simply forgetting. This is the missing axis: which of the things an
/// agent does the activity is showing.
///
/// It is deliberately *not* `AgentEvent.Category`. Those five describe a row in
/// the Inbox; this describes the lifecycle of an activity, and the two have
/// different members (`sessionEnded` is a lifecycle state, not an event an
/// agent sends). Keeping them apart is what stops a sixth row category from
/// silently becoming a lifecycle state, or the reverse.
///
/// Foundation-only and in `App/Shared` so both the app and the widget extension
/// compile the same definition and the same strings — a phase whose glyph or
/// headline differed between the two would render one thing on the Lock Screen
/// and another in the Dynamic Island.
public enum ActivityPhase: String, Codable, Hashable, CaseIterable {
    /// Something is waiting on the user. The only phase that asks.
    case approvalRequired = "approval_required"
    /// A tool is mid-flight — the agent is working and nothing is asked.
    case toolRunning = "tool_running"
    /// The newest thing is finished: a turn ended, or a tool call returned.
    case taskComplete = "task_complete"
    /// The session itself ended. Final: the activity lingers and then dismisses
    /// rather than being yanked away the instant the agent stops.
    case sessionEnded = "session_ended"

    /// Whether the phase is asking the user for something. Drives the tint and
    /// the icon, so "nothing needs you" never wears the raised hand.
    public var isAwaiting: Bool { self == .approvalRequired }

    /// Whether this is the last thing the activity will say. A final phase is
    /// dismissed on a linger rather than immediately, so the user gets to see
    /// *that it ended* instead of watching it disappear.
    public var isFinal: Bool { self == .sessionEnded }

    /// The glyph for the phase. One mapping, used by the Lock Screen, the
    /// Dynamic Island and the watch, because three copies of this switch is
    /// three places for "finished" to end up with the raised hand.
    public var symbol: String {
        switch self {
        case .approvalRequired: "hand.raised.fill"
        case .toolRunning: "gearshape.2.fill"
        case .taskComplete: "checkmark.circle.fill"
        case .sessionEnded: "flag.checkered"
        }
    }

    /// The phase's one-line name, for a header that has room for it.
    public var shortLabel: String {
        switch self {
        case .approvalRequired: "Approval needed"
        case .toolRunning: "Working"
        case .taskComplete: "Done"
        case .sessionEnded: "Session ended"
        }
    }
}