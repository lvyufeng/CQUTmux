import SwiftUI
import UIKit

/// Live view of a booted iOS simulator running on the host. Mirrors Moshi's
/// simulator preview: pick a simulator, and the app shows its screen, polling
/// for a fresh frame while it is on screen.
///
/// The frames come back as PNGs over the SSH tunnel via the host gateway —
/// the host runs `simctl io … screenshot` for us, so the phone needs nothing
/// but the gateway.
struct SimulatorPreviewView: View {
    let client: HookClient

    @Environment(\.dismiss) private var dismiss

    @State private var board: SimulatorBoard?
    @State private var selected: SimulatorBoard.Simulator?
    @State private var frame: UIImage?
    @State private var error: String?
    @State private var loading = true
    @State private var interval: Double = 1.5

    var body: some View {
        NavigationStack {
            Group {
                if let selected {
                    deviceView(selected)
                } else {
                    picker
                }
            }
            .navigationTitle(selected?.name ?? "Simulators")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if selected != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            selected = nil
                            frame = nil
                        } label: {
                            Label("Simulators", systemImage: "rectangle.stack")
                        }
                    }
                }
            }
            .task { await loadList() }
            .task(id: selected?.udid) {
                guard let selected else { return }
                await poll(selected)
            }
        }
    }

    @ViewBuilder
    private var picker: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("Finding simulators…") }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            if let simulators = board?.simulators, !simulators.isEmpty {
                Section("Booted") {
                    ForEach(simulators) { sim in
                        Button {
                            selected = sim
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sim.name).font(.subheadline)
                                Text(sim.runtime).font(.caption2).foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            } else if !loading && error == nil {
                ContentUnavailableView {
                    Label("No booted simulators", systemImage: "iphone.slash")
                } description: {
                    Text("Boot a simulator on the host and it will show up here.")
                }
            }
        }
    }

    @ViewBuilder
    private func deviceView(_ sim: SimulatorBoard.Simulator) -> some View {
        VStack(spacing: 0) {
            if let frame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                ProgressView("Waiting for the first frame…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Text(interval == 0 ? "Paused" : "Updating every \(interval, specifier: "%.1f")s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(interval == 0 ? "Resume" : "Pause") {
                    interval = interval == 0 ? 1.5 : 0
                }
                .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func loadList() async {
        loading = true
        defer { loading = false }
        for _ in 0..<40 {
            switch client.state {
            case .connected:
                do {
                    let board = try await client.simulators()
                    self.board = board
                    #if DEBUG
                    // UI runs can jump straight to a device to exercise polling.
                    if let udid = ProcessInfo.processInfo.environment["CQUT_DEV_SIM_UDID"] {
                        selected = board.simulators.first { $0.udid == udid } ?? board.simulators.first
                    }
                    #endif
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
        error = "Timed out connecting to the host."
    }

    /// Polls frames until the view goes away or the user pauses. The `task(id:)`
    /// modifier cancels this when `selected` changes.
    private func poll(_ sim: SimulatorBoard.Simulator) async {
        while !Task.isCancelled {
            if interval > 0 {
                if let data = try? await client.simulatorScreenshot(udid: sim.udid),
                   let image = UIImage(data: data) {
                    frame = image
                    error = nil
                } else {
                    error = "Couldn't fetch a frame."
                }
                try? await Task.sleep(for: .seconds(interval))
            } else {
                // Paused: idle without spinning.
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}