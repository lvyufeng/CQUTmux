import WidgetKit
import SwiftUI
import ActivityKit

@main
struct CQUTmuxWidgets: WidgetBundle {
    var body: some Widget {
        AgentApprovalWidget()
    }
}

struct AgentApprovalWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentActivityView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.green)
                // A tap lands on the Inbox, whichever tab was last open. The
                // notification is about a pending approval and the answer is on
                // the Inbox, so landing anywhere else makes the user navigate
                // to the thing they were just told about.
                .widgetURL(URL(string: "cqutmux://inbox"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.state.pending)", systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.hostName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.latestSource).font(.caption2).foregroundStyle(.green)
                        Text(context.state.latestTitle).font(.subheadline).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            } compactTrailing: {
                Text("\(context.state.pending)").font(.caption2.weight(.bold))
            } minimal: {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            }
        }
        // Surfaces the same activity on the watch's Smart Stack, where a
        // pending approval is exactly the thing worth raising a wrist for. The
        // families tell the system which watch layouts to use; the view below
        // picks one to match.
        .supplementalActivityFamilies([.small, .medium])
    }
}

/// The Live Activity's content, in whichever size the system asks for.
///
/// The phone's Lock Screen and the watch are different shapes — one is a wide
/// row, the other a couple of lines on a 45mm face — so they are two views
/// rather than one stretched. The family is read from the environment, which is
/// how WidgetKit reports where this instance is being drawn.
struct AgentActivityView: View {
    let context: ActivityViewContext<AgentActivityAttributes>

    /// `.small` is the watch. Guarded rather than switched exhaustively: the
    /// environment value is only meaningful on iOS 18+, and a build against an
    /// older SDK must still compile.
    @Environment(\.activityFamily) private var family

    var body: some View {
        if family == .small {
            watch
        } else {
            lockScreen
        }
    }

    /// The phone's Lock Screen: a wide row with the count, the agent and what
    /// it is asking about.
    private var lockScreen: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(context.state.pending) approval\(context.state.pending == 1 ? "" : "s") waiting")
                    .font(.headline)
                Text("\(context.state.latestSource) · \(context.state.latestTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding()
    }

    /// The watch face's Smart Stack: the count has to be readable at a glance
    /// and nothing else is worth the space. The agent name goes underneath
    /// because with several agents running "2 waiting" alone does not say which
    /// one is stuck.
    private var watch: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(context.state.pending) waiting")
                    .font(.headline)
                    .lineLimit(1)
                Text(shortSource)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
    }

    /// The agent name, shortened for a watch-width line. A long source is cut
    /// at a word boundary rather than mid-word, because a truncated identifier
    /// reads as a different agent.
    private var shortSource: String {
        let source = context.state.latestSource
        guard source.count > 14 else { return source }
        let cut = source.prefix(14)
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space])
        }
        return String(cut)
    }
}