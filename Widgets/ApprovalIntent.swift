import AppIntents
import Foundation

/// Allows or denies an approval from the Live Activity.
///
/// This runs in whichever process the system chooses — the widget extension, or
/// the app — and it cannot talk to the host directly: the gateway lives behind
/// an SSH tunnel the extension has no connection to. So it does the one thing it
/// can, which is to put the decision in the App Group, and the app sends it the
/// next time it runs. The decision is not lost in between; it waits.
///
/// The event id is passed in by the widget when it builds the button, so the tap
/// names the approval it is answering rather than relying on any state being
/// read back later — the activity may have been updated or ended by the time the
/// intent runs.
struct ApprovalIntent: AppIntent {
    static var title: LocalizedStringResource = "Answer approval"

    /// Not a foreground action: the point is to answer without opening the app.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Event")
    var event: Int

    @Parameter(title: "Allow")
    var allow: Bool

    init() {}

    init(event: Int, allow: Bool) {
        self.event = event
        self.allow = allow
    }

    func perform() async throws -> some IntentResult {
        MobileDecisionQueue().enqueue(
            MobileDecision(id: event, allow: allow, at: Date())
        )
        return .result()
    }
}
