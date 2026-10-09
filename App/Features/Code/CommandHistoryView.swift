import SwiftUI

/// The commands recently run on the host, read from the shell's own history.
///
/// This exists because the host is where the command was typed the first time.
/// A phone keyboard makes retyping `kubectl logs -f deploy/api -n prod` a
/// misery, and the command is already sitting in `~/.zsh_history` — so the app
/// asks for it rather than trying to scrape a terminal pane and guess.
///
/// The chosen command is *typed*, not run. It lands in the shell's line editor
/// with the cursor after it, so it can be read and edited before Return. That is
/// the difference between a convenience and a way to run something the user did
/// not look at.
struct CommandHistoryView: View {
    let client: HookClient
    /// Hands the command back to the terminal. The caller types it.
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var board: CommandHistoryBoard?
    @State private var query = ""
    @State private var failure: String?

    private var commands: [CommandHistoryBoard.Entry] {
        let all = board?.commands ?? []
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.command.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        List {
            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            if board == nil {
                Section {
                    HStack {
                        ProgressView()
                        Text("Reading the host's history…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if board?.available == false {
                Section {
                    Text("The gateway answered, but could not read a history file.")
                        .foregroundStyle(.secondary)
                }
            } else if commands.isEmpty {
                Section {
                    // Two different empties, and they mean different things: a
                    // search that matched nothing is not the same as a host with
                    // no history, and saying "no commands" for the first would
                    // read as the host having lost them.
                    Text(query.isEmpty
                         ? "No commands were found in the shell's history."
                         : "No command matches “\(query)”.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(commands) { entry in
                        Button {
                            onPick(entry.command)
                            dismiss()
                        } label: {
                            row(entry)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Tapped commands are typed into the terminal, not run. Read it, then press Return.")
                        .font(.caption)
                }
            }
        }
        .searchable(text: $query, prompt: "Filter commands")
        .navigationTitle("Command History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task { await load() }
    }

    private func row(_ entry: CommandHistoryBoard.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.firstLine)
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(2)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)

            HStack(spacing: 6) {
                // A multi-line command is marked rather than expanded: the
                // picker's job is to find the right command, and a row that
                // grew to eight lines would push the next ones off screen.
                if entry.isMultiline {
                    Text("⏎ \(entry.continuation)")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let at = entry.at {
                    Text(Date(timeIntervalSince1970: at / 1000), format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    // A plain-format record has no time, which is not an error.
                    // Showing a fabricated one would be worse than showing none.
                    Text(entry.shell)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        // Wait for the tunnel rather than firing once at whatever the state
        // happens to be. The sheet can be opened before the gateway's SSH
        // connection has finished coming up — and when it opens automatically
        // from a debug hook it usually is — so a single attempt reports a
        // network error that is really just an unfinished connection. Ten
        // seconds is generous for a tunnel that will connect at all, and a
        // gateway that is genuinely down still fails at the end of it.
        for _ in 0..<20 {
            if client.state == .connected { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        do {
            let loaded = try await client.commandHistory()
            board = loaded
            if loaded.available == false, let error = loaded.error {
                failure = error
            }
        } catch {
            failure = error.localizedDescription
            // An empty board rather than a spinner forever: the failure is
            // already reported above it.
            board = CommandHistoryBoard(available: false, commands: [])
        }
    }
}