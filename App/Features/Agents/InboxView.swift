import SwiftUI
import UIKit

/// The agent feed. Mirrors Moshi's Inbox: a host picker, pending approvals
/// with Allow / Deny, and a running log of what agents have been doing.
struct InboxView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(HostStore.self) private var store
    @Environment(AgentConnection.self) private var connection
    @Environment(AppSettings.self) private var app

    @State private var segment: Segment = .inbox
    @State private var activity = ActivityManager()
    @State private var ledger = NotificationLedger()
    @State private var context = ContextStore()
    @State private var sawFirstPage = false
    /// Rows the user swiped away. Kept here rather than discarded, because the
    /// row is rebuilt from the event list on every poll and would otherwise
    /// come straight back.
    @State private var archived: Set<String> = []
    /// Archived rows are behind a disclosure rather than gone: "Archived" is a
    /// place to check what happened, and a row that vanishes with no way to
    /// look it up is how the inbox becomes untrustworthy.
    @State private var showArchived = false

    private enum Segment: String, CaseIterable { case inbox = "Inbox", usages = "Usages" }

    var body: some View {
        Group {
            if store.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No hosts", systemImage: "server.rack")
                } description: {
                    Text("Add a host on the Terminal tab, install cqutmux-hook on it, then pick it here.")
                }
            } else if let client = connection.client {
                feed(client)
            } else {
                ContentUnavailableView {
                    Label("Pick a host", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text(connection.lastError ?? "Choose which machine's agent feed to watch.")
                } actions: {
                    hostMenu
                }
            }
        }
        .navigationTitle("Inbox")
        // Held while this screen is in front, released the moment it is not —
        // via the `onChange` as well as `onDisappear`, because a tab switch does
        // not always run the disappearance before the next appearance, and a
        // phone left awake by a screen nobody is looking at is the exact failure
        // this setting is meant to avoid.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = app.keepScreenOn }
        .onChange(of: app.keepScreenOn) { _, on in
            UIApplication.shared.isIdleTimerDisabled = on
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task {
            #if DEBUG
            // Same escape hatch as the shell's: seeding a host and connecting
            // to it are separate things, and a run that wants to look at the
            // host list itself must not be dragged into a session.
            if ProcessInfo.processInfo.environment["CQUT_DEV_NO_CONNECT"] != "1",
               connection.client == nil,
               let target = store.hosts.first(where: { $0.hostname == ProcessInfo.processInfo.environment["CQUT_DEV_HOST"] }) {
                connection.connect(to: target)
            }
            #endif
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu { hostMenu } label: {
                    Label("Host", systemImage: "server.rack")
                }
            }
        }
    }

    @ViewBuilder
    private var hostMenu: some View {
        ForEach(store.hosts) { host in
            Button("\(host.displayName) — \(host.target)") {
                connection.connect(to: host)
            }
        }
    }

    @ViewBuilder
    private func feed(_ client: HookClient) -> some View {
        switch segment {
        case .inbox:
            List {
                if case .failed(let message) = client.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
                if client.events.isEmpty {
                    Section {
                        // A connected client with nothing to show is either
                        // genuinely idle or failing to read the gateway, and
                        // those look identical without the error. "Waiting for
                        // agent activity" while every poll times out is the one
                        // message that sends someone looking in the wrong place.
                        if let error = client.lastError {
                            Text("Connected, but the gateway is not answering: \(error)")
                                .foregroundStyle(.orange)
                                .font(.footnote)
                        } else {
                            Text(client.state == .connected ? "Waiting for agent activity…" : "Connecting to the host…")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                    }
                }
                let board = InboxBoard(events: client.events, manuallyArchived: archived)
                BoardView(
                    board: board,
                    resolve: { event, allow in client.resolve(event, allow: allow) },
                    answer: { event, value in client.resolve(event, answer: value) },
                    archive: { archived.insert($0.id) },
                    showArchived: $showArchived,
                    context: context
                )
                // The ring reads the agent's transcript for tokens the events
                // do not carry, so it is fetched here once per session rather
                // than per row per poll. Driven off the board's own rows so it
                // follows the sessions actually on screen, not the whole host.
                .task(id: contextKey(board)) {
                    await context.refresh(
                        directories: board.active.compactMap(\.directory),
                        via: client,
                        limit: app.contextLimit
                    )
                }
            }
            .listStyle(.insetGrouped)
            .onChange(of: app.contextLimit) { _, _ in
                // A new denominator invalidates every fraction, so the readings
                // are dropped and the task above refetches against the new one.
                context.invalidate()
            }
            .onChange(of: client.events) { _, events in
                let hostName = connection.host?.displayName ?? "Host"
                activity.update(hostName: hostName, events: events)
                let fresh = ledger.fresh(from: events, isFirstLoad: !sawFirstPage)
                sawFirstPage = true
                if !fresh.isEmpty { Task { await ApprovalNotifier.notify(fresh, hostName: hostName) } }
            }
        case .usages:
            ContentUnavailableView {
                Label("Usages", systemImage: "gauge.with.dots.needle.50percent")
            } description: {
                Text("Rate-limit burn pace per agent lands here.")
            }
        }
    }

    /// Identity for the fetch task: the set of directories currently on the
    /// board, so a session appearing or leaving re-runs the pass and a repaint
    /// that changes nothing does not.
    private func contextKey(_ board: InboxBoard) -> String {
        board.active.compactMap(\.directory).sorted().joined(separator: "|") + "#\(app.contextLimit)"
    }
}

/// The board: three columns, one row per session, and an archive underneath.
///
/// Moshi's shape, and the reason for it is that the flat list it replaced made
/// the user do the reading. Twenty events from one session were twenty rows, so
/// the one thing waiting on an answer sat somewhere among them, and it never
/// left the list afterwards either.
private struct BoardView: View {
    let board: InboxBoard
    let resolve: (AgentEvent, Bool) -> Void
    let answer: (AgentEvent, String) -> Void
    let archive: (InboxBoard.Row) -> Void
    @Binding var showArchived: Bool
    /// Shared, so a reading fetched for one row is there for its group header
    /// and for the row again after a repaint, rather than once per appearance.
    let context: ContextStore

    var body: some View {
        ForEach(InboxBoard.Column.allCases) { column in
            let groups = board.groups(in: column)
            // A column with nothing in it is not drawn at all: three headings,
            // two of them empty, is a screen that looks broken rather than
            // quiet. `groups` is never empty for a column with no rows — it
            // returns one empty group, so emptiness has to be judged on the
            // rows.
            if !groups.flatMap(\.rows).isEmpty {
                Section(column.title) {
                    ForEach(groups, id: \.project) { group in
                        // A header only when the column really spans projects.
                        // One unnamed group means there is nothing to separate,
                        // and a lone heading over every row is noise.
                        if !group.project.isEmpty && groups.count > 1 {
                            Text(group.project)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(group.rows) { row in
                            SessionRow(row: row, resolve: resolve, answer: answer, context: context)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        archive(row)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                }
                        }
                    }
                }
            }
        }

        if !board.archived.isEmpty {
            Section {
                if showArchived {
                    ForEach(board.archived) { row in
                        SessionRow(row: row, resolve: resolve, answer: answer, context: context)
                    }
                }
            } header: {
                // A disclosure rather than a second screen: the archive is
                // consulted, not lived in.
                Button {
                    withAnimation { showArchived.toggle() }
                } label: {
                    Label(
                        showArchived ? "Hide archived" : "Archived (\(board.archived.count))",
                        systemImage: showArchived ? "chevron.down" : "chevron.right"
                    )
                }
                .textCase(nil)
            }
        }
    }
}

/// One session's row: what it is, what it needs, and the history folded away.
private struct SessionRow: View {
    let row: InboxBoard.Row
    let resolve: (AgentEvent, Bool) -> Void
    let answer: (AgentEvent, String) -> Void
    let context: ContextStore
    @State private var expanded = false
    /// Whether the pending prompt's body has been expanded to its full length.
    /// Per row, so opening one does not open every pending prompt on the board.
    @State private var readFirst = false
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: row.pending != nil ? "hand.raised.fill" : icon)
                    .foregroundStyle(row.pending != nil ? .orange : themes.current.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.subheadline.weight(.medium))
                    // The newest event is the row's own summary; the count says
                    // how much is folded behind it, so a row is never mistaken
                    // for a conversation of one.
                    Text(summary).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                // Only once a reading has arrived. A session the gateway cannot
                // read leaves the slot empty rather than drawing a ring against
                // a number nobody measured.
                if let directory = row.directory,
                   let usage = context.reading(for: directory) {
                    ContextRing(usage: usage)
                }
            }

            if let event = row.pending {
                // What the agent is actually asking. The row's own line is the
                // *title* — the tool name — and without this the prompt was
                // answered from that alone, which is the "answer blind" case:
                // the body is the command or the file being changed, and it is
                // the part being approved.
                //
                // Shown whole for a question (its text is the question) and
                // clamped for a tool input, with a toggle for the rest. The
                // calling is the model's — `promptText` is the body with the
                // tool input taken apart into lines, `promptClampLines` and
                // `promptOffersReading` decide how much shows and whether
                // there is anything to reveal. Checked in `scripts/inbox-check.sh`:
                // a line limit cannot be read off a screenshot in the direction
                // that matters.
                if !event.promptText.isEmpty {
                    Text(event.promptText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(readFirst ? nil : event.promptClampLines)
                        .textSelection(.enabled)
                }
                // The toggle's count is the lines the clamp is actually
                // hiding, so the two numbers on screen agree.
                if event.promptOffersReading {
                    let hidden = event.promptLineCount - AgentEvent.promptClampLines
                    Button(
                        readFirst ? "Show less" : "Read first (\(hidden) more lines)"
                    ) {
                        withAnimation { readFirst.toggle() }
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(themes.current.accentColor)
                }
                EventActions(event: event, resolve: resolve, answer: answer)
            }

            if row.events.count > 1 {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Label(
                        expanded ? "Hide \(row.events.count) events" : "\(row.events.count) events",
                        systemImage: expanded ? "chevron.down" : "chevron.right"
                    )
                    .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if expanded {
                    // Oldest last, which is the order a log is read in. The
                    // pending event is left out: it is already on the row in
                    // full, and repeating it inside the history would suggest
                    // two things are waiting.
                    ForEach(row.events.filter { $0.id != row.pending?.id }) { event in
                        CompactEventRow(event: event, resolve: resolve, answer: answer)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch row.column {
        case .needsYou: "hand.raised"
        case .working: "gearshape.2"
        case .done: "checkmark.circle"
        }
    }

    private var summary: String {
        guard let newest = row.events.first else { return row.subtitle }
        let when = relative(newest.date)
        let who = newest.sourceLabel
        let what = newest.displayTitle.isEmpty ? "activity" : newest.displayTitle
        return when.isEmpty ? "\(who) · \(what)" : "\(who) · \(what) · \(when)"
    }
}

/// A folded event: enough to recognise it, not enough to take the row over.
private struct CompactEventRow: View {
    let event: AgentEvent
    let resolve: (AgentEvent, Bool) -> Void
    let answer: (AgentEvent, String) -> Void
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: event.isPending ? "hand.raised" : event.kind == .approval ? "checkmark.circle" : "bell")
                    .font(.caption2)
                    .foregroundStyle(event.isPending ? .orange : themes.current.accentColor)
                Text(event.displayTitle.isEmpty ? event.sourceLabel : event.displayTitle)
                    .font(.caption)
                    .lineLimit(2)
                Spacer(minLength: 6)
                Text(relative(event.date)).font(.caption2).foregroundStyle(.secondary)
            }
            if !event.displayBody.isEmpty {
                Text(event.displayBody).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            if event.isPending {
                EventActions(event: event, resolve: resolve, answer: answer)
            } else if let chosen = event.chosenOption {
                Text("Chose: \(chosen.label)").font(.caption2).foregroundStyle(.secondary)
            } else if let decision = event.decision {
                Text(decision == "allow" ? "Approved" : "Denied")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 14)
        .padding(.vertical, 2)
    }
}

/// The controls for answering an event, shared by the row's own pending event
/// and by a pending one found inside the expanded history.
private struct EventActions: View {
    let event: AgentEvent
    let resolve: (AgentEvent, Bool) -> Void
    let answer: (AgentEvent, String) -> Void
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        // A question is answered by picking one of its options; asking it as
        // Allow/Deny would throw away the choice it was asked to make. Stacked
        // rather than in a row because option labels are sentences, and a row
        // of sentences truncates into ambiguity.
        if event.isQuestion {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(event.options) { option in
                    Button(option.label) { answer(event, option.value) }
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        } else {
            HStack(spacing: 10) {
                Button("Allow") { resolve(event, true) }
                    .buttonStyle(.borderedProminent)
                    .tint(themes.current.accentColor)
                Button("Deny", role: .destructive) { resolve(event, false) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
    }
}

/// Relative time, or empty when the timestamp could not be read — a blank is
/// better than "now", which is what a nil-relative fallback would claim.
///
/// A timestamp in the future is read as "now". The host writes these, and a
/// device whose clock is a few seconds behind it turns every event that has
/// just arrived into "in 3s" — which reads as a countdown to something that has
/// already happened.
func relative(_ date: Date?) -> String {
    guard let date else { return "" }
    let now = Date()
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: min(date, now), relativeTo: now)
}
