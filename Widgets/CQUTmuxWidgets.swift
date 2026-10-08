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
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.green)
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
    }

    private func lockScreen(_ context: ActivityViewContext<AgentActivityAttributes>) -> some View {
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
}