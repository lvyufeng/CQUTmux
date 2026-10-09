import SwiftUI

/// A small ring on an Inbox row showing how full the agent's context window is,
/// with the remaining tokens beside it.
///
/// The number comes from the agent's own transcript log (`ContextWindow`), not
/// from the events the gateway emits: the events carry no token counts, and the
/// log is the only place the agent records what it sent. The ring appears on a
/// row only once a reading has arrived — no placeholder, because a spinner that
/// never resolves into a number is worse than an empty slot, and a wrong
/// number is worse than both.
struct ContextRing: View {
    let usage: ContextWindow.Usage
    @Environment(ThemeStore.self) private var themes

    /// The visible ring's size. Small: it is an indicator on a row that already
    /// carries an icon, a title, a summary and a status dot, and a control-sized
    /// ring would compete with the thing it is annotating.
    private let diameter: CGFloat = 22

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 2.5)
                Circle()
                    // Drawn from the top and clockwise, which is how every
                    // progress ring on the platform reads.
                    .trim(from: 0, to: usage.fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: diameter, height: diameter)

            // Hidden rather than shown as a full ring alone: the ring is
            // glanceable, the number is what you read when it matters, and the
            // two have to fit where the summary already is.
            Text(percentLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(usage.isWarning ? .orange : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context window")
        .accessibilityValue(accessibilityValue)
        .help(accessibilityValue)
    }

    /// Red at the warning band, the theme's accent below it — the same pair the
    /// Watch complication uses so the two never disagree about "nearly full".
    private var tint: Color {
        usage.isWarning ? .orange : themes.current.accentColor
    }

    private var percentLabel: String {
        "\(Int((usage.fraction * 100).rounded()))%"
    }

    private var accessibilityValue: String {
        let remaining = usage.remaining
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let left = formatter.string(from: NSNumber(value: remaining)) ?? "\(remaining)"
        return "\(percentLabel) used, \(left) tokens left"
    }
}

/// Reads and caches each session's context-window reading.
///
/// An `@Observable` store rather than a `.task` on the row because the row is
/// rebuilt on every poll and would refetch its transcript each time — a
/// transcript read is a file read on the host and the poll is every few
/// seconds, so a per-row fetch would be a lot of traffic for a number that
/// changes once per agent turn.
@Observable
@MainActor
final class ContextStore {
    private(set) var readings: [String: ContextWindow.Usage] = [:]
    /// Directories already asked about, so a session whose log cannot be read
    /// is not re-requested on every poll. Cleared when the limit changes,
    /// because a new limit re-derives every reading from the same logs.
    private var attempted: Set<String> = []
    private var inFlight: Set<String> = []

    func reading(for directory: String) -> ContextWindow.Usage? {
        readings[directory]
    }

    /// Forgets everything, so the next pass refetches. Called when the limit
    /// changes: the tokens are the agent's, but the fraction is against a
    /// denominator this app owns.
    func invalidate() {
        readings.removeAll()
        attempted.removeAll()
    }

    /// Fetches readings for the directories that do not have one yet.
    ///
    /// Serial and best-effort: a session with no readable log is simply left
    /// without a ring, which is the honest state — the alternative is a ring
    /// drawn against an assumed number for a session nobody could read.
    func refresh(directories: [String], via client: HookClient, limit: Int) async {
        guard limit > 0 else { return }
        for directory in directories where !attempted.contains(directory) && !inFlight.contains(directory) {
            inFlight.insert(directory)
            defer { inFlight.remove(directory) }
            // Marked attempted whether or not it succeeds: a directory the
            // gateway cannot read will keep failing, and retrying it every poll
            // is how a missing log turns into a stream of requests.
            attempted.insert(directory)
            guard let transcript = try? await client.transcript(path: directory, limit: 40) else { continue }
            if let usage = ContextWindow.usage(from: transcript.messages, limit: limit) {
                readings[directory] = usage
            }
        }
    }
}