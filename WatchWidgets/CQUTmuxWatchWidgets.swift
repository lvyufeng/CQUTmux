import WidgetKit
import SwiftUI

/// The watch face's complication: how close the busiest account is to its
/// rate-limit window.
///
/// One number rather than a list, because that is what a complication is for —
/// a glance that answers "am I about to be cut off". Which window it shows is
/// decided by `WatchPayload.Usage.peakPercent`, the same rule the Usage screen
/// uses, so the face and the app cannot disagree about which account is tightest.
///
/// It reads from the App Group rather than WatchConnectivity: this is a
/// separate process with its own container, and `WCSession`'s received context
/// is not available to it. The watch app mirrors each pushed usage payload into
/// the shared defaults; this reads whatever is there.
@main
struct CQUTmuxWatchWidgets: WidgetBundle {
    var body: some Widget {
        UsageComplication()
    }
}

/// A single reading, decoded from the shared container. `Date` is the refresh
/// time so WidgetKit can age it out rather than showing a stale number as
/// current — the payload carries the phone's own `generatedAt`, and that is the
/// one shown, not the moment this was read.
struct UsageEntry: TimelineEntry {
    var date: Date
    var peak: Double?
    var source: String?
    /// When the phone took the reading, so the face can say how old it is.
    var generatedAt: Date?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), peak: 0.62, source: "Claude Code", generatedAt: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = read()
        // Refreshed every fifteen minutes as a floor. The real trigger is the
        // watch app calling `reloadAllTimelines` when a fresh payload arrives,
        // so this only covers the phone having nothing new to say.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func read() -> UsageEntry {
        guard let defaults = WatchPayload.sharedDefaults,
              let data = defaults.data(forKey: WatchPayload.sharedUsageKey),
              let usage = WatchPayload.decode(WatchPayload.Usage.self, from: data)
        else {
            // No App Group, or nothing pushed yet. Both look the same from
            // here: a face with nothing to show.
            return UsageEntry(date: Date(), peak: nil, source: nil, generatedAt: nil)
        }
        let tightest = usage.entries.max { lhs, rhs in
            (lhs.tightest?.percent ?? -1) < (rhs.tightest?.percent ?? -1)
        }
        return UsageEntry(
            date: Date(),
            peak: usage.peakPercent,
            source: tightest?.label,
            generatedAt: usage.generatedAt
        )
    }
}

struct UsageComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CQUTmuxUsage", provider: UsageProvider()) { entry in
            UsageComplicationView(entry: entry)
                // A tap opens the Usage screen through the same deep link the
                // rest of the app uses; the watch app routes it on launch.
                .widgetURL(URL(string: "cqutmux://usage"))
        }
        .configurationDisplayName("Agent usage")
        .description("How close your busiest agent is to its rate limit.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

struct UsageComplicationView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: (entry.peak ?? 0) / 100) {
                Image(systemName: "gauge.with.dots.needle.50percent")
            } currentValueLabel: {
                Text(percentText)
            }
            .gaugeStyle(.accessoryCircular)
        case .accessoryCorner:
            Text(percentText)
                .font(.headline)
                .widgetLabel {
                    Gauge(value: (entry.peak ?? 0) / 100) { Text("Usage") }
                }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.source ?? "Agent usage")
                    .font(.caption2)
                    .lineLimit(1)
                Text(percentText + (entry.peak == nil ? "" : " of the tightest window"))
                    .font(.headline)
            }
        default:
            entry.peak == nil
                ? Text("No usage")
                : Text("\(entry.source ?? "Agent") \(percentText)")
        }
    }

    /// "—" rather than "0%" when there is no reading: an empty ring reads as a
    /// measured zero, which is a reassuring lie when the truth is unknown.
    private var percentText: String {
        guard let peak = entry.peak else { return "—" }
        return "\(Int(peak.rounded()))%"
    }
}