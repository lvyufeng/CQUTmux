import SwiftUI

/// Rate-limit burn pace per agent, mirroring Moshi's Usages board: 5h and 7d
/// windows with a progress bar, percent used, and time until reset.
struct UsagesView: View {
    @Environment(AgentConnection.self) private var connection

    @State private var board: UsageBoard?
    @State private var error: String?

    var body: some View {
        Group {
            if let board, !board.entries.isEmpty {
                List {
                    ForEach(board.entries) { entry in
                        Section {
                            ForEach(entry.windows) { window in
                                UsageRow(window: window)
                            }
                            if let pace = entry.pace {
                                Text(pace).font(.caption2).foregroundStyle(.secondary)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: "circle.hexagongrid.fill")
                                    .foregroundStyle(Theme.accent)
                                Text(entry.label)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No usage data", systemImage: "gauge.with.dots.needle.50percent")
                } description: {
                    Text(error ?? "The host hook reports rate limits here once an agent has produced usage.")
                }
            }
        }
        .navigationTitle("Usages")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let client = connection.client else {
            error = "Pick a host on the Inbox tab first."
            return
        }
        for _ in 0..<40 {
            switch client.state {
            case .connected:
                do {
                    board = try await client.usage()
                    error = nil
                } catch {
                    self.error = "\(error)"
                }
                return
            case .failed(let message):
                error = message
                return
            default:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

private struct UsageRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.label).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(window.percent))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(window.percent > 85 ? .red : .primary)
                if let reset = window.resetIn {
                    Text("reset \(reset)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * min(window.percent, 100) / 100)
                }
            }
            .frame(height: 6)
        }
    }

    private var tint: Color {
        switch window.percent {
        case ..<60: Theme.accent
        case ..<85: .yellow
        default: .red
        }
    }
}