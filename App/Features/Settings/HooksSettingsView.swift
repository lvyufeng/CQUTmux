import SwiftUI
import ActivityKit

/// Settings → Hooks: the parts of the agent integration that live on this
/// device rather than on the host.
///
/// The host's hook settings are a file in `~/.config/cqutmux/config.toml` and
/// are reported by `cqutmux status`; nothing here reaches the host. What is
/// here is what the app does with the events the hooks send — whether a pending
/// approval gets a Live Activity, whether tapping that activity lands on the
/// Inbox, and a way to see both work without waiting for a real approval.
struct HooksSettingsView: View {
    /// The same keys `AgentActivitySettings` gates on, read through
    /// `@AppStorage` so the toggle and the runtime decision cannot hold
    /// different values. The default is `true`, which is what the enum answers
    /// for a device that has never opened this screen.
    @AppStorage(AgentActivitySettings.enabledKey) private var liveActivities = true
    @AppStorage(AgentActivitySettings.openInboxKey) private var openInboxOnTap = true

    @State private var activity = ActivityManager()
    @State private var testSummary: String?

    /// Whether iOS itself will allow an activity. A Live Activity can be turned
    /// off for the app in the system settings, and when it is, nothing this
    /// screen does produces one. Saying so is the difference between a bug
    /// report and a switch to flip.
    private var systemAllows: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var body: some View {
        List {
            Section {
                Toggle("Live Activity for pending approvals", isOn: $liveActivities)
                    .disabled(!systemAllows)
                if systemAllows {
                    Toggle("Open Inbox on tap", isOn: $openInboxOnTap)
                        .disabled(!liveActivities)
                }
            } header: {
                Label("Live Activity", systemImage: "bolt.badge.clock")
            } footer: {
                Text(footer)
            }

            Section {
                Button("Send a test activity") { sendTest() }
                    .disabled(!systemAllows || !liveActivities)
                if let testSummary {
                    Text(testSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Test", systemImage: "testtube.2")
            } footer: {
                Text("Puts the activity on the Lock Screen with two made-up approvals — "
                     + "enough that the count and the plural are both visible. It goes "
                     + "away on its own when the next real poll arrives, or with the "
                     + "button below.")
            }

            Section {
                Button("End the activity", role: .destructive) {
                    activity.end()
                    testSummary = nil
                }
                .disabled(testSummary == nil)
            } footer: {
                Text("Only the test activity: a real pending approval will put one "
                     + "back the next time the Inbox polls.")
            }
        }
        .navigationTitle("Hooks")
        .navigationBarTitleDisplayMode(.inline)
        // Turning the switch off has to take an activity that is already on the
        // Lock Screen with it. Waiting for the next poll would leave a badge
        // asking for attention that the user has just said they do not want.
        .onChange(of: liveActivities) { _, on in
            if !on {
                activity.end()
                testSummary = nil
            }
        }
    }

    private var footer: String {
        if !systemAllows {
            return "Live Activities are turned off for CQUTmux in iOS Settings. "
                + "Turn them on in Settings → CQUTmux → Live Activities, then come back."
        }
        return "While an approval is waiting, the app keeps an activity on the Lock "
            + "Screen and in the Dynamic Island showing how many are pending and what "
            + "the newest one is. It is started and updated by the app itself, so it "
            + "needs the app to have seen the event — a notification can arrive first "
            + "when the app is not running."
    }

    private func sendTest() {
        let events = AgentActivityPreview.sampleEvents()
        let outcome = activity.update(hostName: "Test host", events: events)
        // The line under the button reports what actually happened rather than
        // what was intended. `Activity.request` throws for reasons the screen
        // cannot predict — the system's per-app activity budget, or activities
        // switched off in iOS Settings — and a test button whose only output is
        // "nothing appeared" is one the user has to guess about.
        testSummary = switch outcome {
        case .started, .updated:
            // Read back through the same decision the activity uses, so the
            // summary cannot drift from what the widget was handed.
            AgentActivityPreview.content(for: events).map { "Showing: \($0.summary)" }
                ?? "Showing: the activity."
        case .nothingToShow:
            "Nothing to show — the activity was ended instead."
        case .disabledInApp:
            "Live activities are switched off above."
        case .unavailable:
            "iOS is not allowing a Live Activity for CQUTmux right now."
        case .failed(let message):
            "Could not start the activity: \(message)"
        case .ended:
            "The activity was ended."
        }
    }
}

#Preview {
    NavigationStack { HooksSettingsView() }
}