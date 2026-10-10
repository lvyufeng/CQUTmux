import SwiftUI

/// Per-account rate-limit rings, mirroring the phone's Usages tab.
///
/// A ring per window rather than a number, because the question a glance
/// answers is "am I near the edge", and that is a proportion. The window
/// closest to its limit is labelled, since that is the one that will stop work.
struct WatchUsageView: View {
    @State private var link = WatchLink.shared

    /// The rings have to be composable from the outside to be checkable: the
    /// real path needs a paired phone, a live gateway and an agent that has
    /// burned quota, none of which a script can arrange. DEBUG-only, and the
    /// view renders it through the same code path a pushed value takes.
    private var usage: WatchPayload.Usage? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CQUT_DEV_WATCH_USAGE"] != nil {
            return Self.fixture
        }
        #endif
        return link.usage
    }

    #if DEBUG
    private static let fixture = WatchPayload.Usage(
        entries: [
            .init(
                source: "claude-code", label: "Claude Code", pace: "on pace",
                windows: [
                    .init(label: "5h", percent: 62, resetIn: "in 2h 10m"),
                    .init(label: "7d", percent: 34, resetIn: "in 4d"),
                ]
            ),
            .init(
                source: "codex", label: "Codex", pace: nil,
                windows: [.init(label: "5h", percent: 88, resetIn: "in 40m")]
            ),
        ],
        generatedAt: Date()
    )
    #endif

    var body: some View {
        Group {
            if let usage, !usage.entries.isEmpty {
                List {
                    ForEach(usage.entries) { entry in
                        Section {
                            ForEach(entry.windows) { window in
                                ring(window)
                            }
                            if let pace = entry.pace {
                                Text(pace)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text(entry.label)
                        }
                    }
                    if let at = usage.generatedAt {
                        Text("Updated \(at, format: .relative(presentation: .named))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No usage yet",
                    systemImage: "gauge.with.dots.needle.50percent",
                    description: Text("Open CQUTmux on your iPhone and connect to a host.")
                )
            }
        }
        .navigationTitle("Usage")
        .onAppear { WatchLink.shared.start() }
    }

    private func ring(_ window: WatchPayload.Usage.Window) -> some View {
        HStack(spacing: 8) {
            Gauge(value: min(max(window.percent, 0), 100), in: 0...100) {
                EmptyView()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint(for: window.percent))
            // The ring is decorative once the percentage is beside it, so it
            // does not need to be the thing VoiceOver reads.
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(window.label).font(.caption)
                // Rounded, and shown even at 0: "0%" is a measurement, and a
                // blank where a number should be reads as missing data.
                Text(window.credit
                     ? "\(Int(window.percent.rounded()))% cr"
                     : "\(Int(window.percent.rounded()))%")
                    .font(.headline)
                    .monospacedDigit()
                if let reset = window.resetIn {
                    Text(reset).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(window.label), \(Int(window.percent.rounded())) percent used"
                + (window.resetIn.map { ", resets \($0)" } ?? "")
        )
    }

    /// Green below half, orange approaching the limit, red past 80%. The bands
    /// are wide on purpose: a colour that changes every few percent is noise on
    /// a screen looked at for a second.
    private func tint(for percent: Double) -> Color {
        switch percent {
        case ..<50: .green
        case ..<80: .orange
        default: .red
        }
    }
}