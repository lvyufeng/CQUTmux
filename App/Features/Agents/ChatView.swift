import SwiftUI

/// The agent's session as a conversation: what was asked, what it reasoned,
/// what it ran, what came back.
///
/// A separate reader from the terminal, not a replacement for it. The terminal
/// is where you type and where a full-screen TUI lives; this is where you read
/// what a long-running agent has been doing without scrolling through its
/// repaints. Both come from the same session — the transcript is the agent's
/// own log and the pane is the process's screen.
struct ChatView: View {
    let client: HookClient
    /// The project directory whose session to read. The transcript is per
    /// directory, so this is also what decides *which* conversation.
    let path: String

    @Environment(ThemeStore.self) private var themes
    @State private var transcript = AgentTranscript.empty
    @State private var error: String?
    @State private var loading = true
    @State private var follow = true
    /// The agent, model and session for the header. Derived from the transcript
    /// on each load rather than stored on the wire: the header is a reading of
    /// the messages, not a field the gateway has to remember to send.
    @State private var header = ChatHeader(agent: "Agent")
    /// The working tree's changes, fetched alongside the transcript so the
    /// header can say what the diff control would open. Nil until the first
    /// fetch lands, which is why the control only appears once it knows.
    @State private var changed: DiffResult?
    @State private var showDiff = false
    @State private var showPreview = false

    /// Reading the log on a timer rather than being pushed to. The log is a
    /// file the agent appends to; there is no event to subscribe to, and a
    /// poll of a local file is cheap enough that a stream would be complexity
    /// for its own sake. Three seconds is short enough to feel live while a
    /// turn is running and long enough not to matter when it is not.
    private let refresh = Duration.seconds(3)

    /// The agent whose log this reads.
    ///
    /// A constant because the gateway's transcript reader knows exactly one
    /// agent's log format (`~/.claude/projects/...`), so naming any other here
    /// would be a header that says something the reader cannot deliver. It
    /// becomes a parameter when a second agent's transcript is readable, not
    /// before.
    private static let agentName = "Claude Code"

    var body: some View {
        Group {
            if loading && transcript.messages.isEmpty {
                ProgressView("Reading the session…")
            } else if let error, transcript.messages.isEmpty {
                ContentUnavailableView {
                    Label("Could not read the session", systemImage: "text.bubble")
                } description: {
                    Text(error)
                }
            } else if transcript.messages.isEmpty {
                ContentUnavailableView {
                    Label("No conversation yet", systemImage: "text.bubble")
                } description: {
                    Text(transcript.found
                         ? "This session has not written anything to its log yet."
                         : "No agent session found for this directory. Start one on the host, then come back.")
                }
            } else {
                conversation
            }
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The agent, its model and the session id, under the title. What
            // each says and how it is shortened is `ChatHeader`'s job — three
            // derivations that fail silently if done inline in a view.
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Chat").font(.headline)
                    Text(header.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    // Both controls only appear when there is something behind
                    // them: a diff button over a clean tree and a preview button
                    // over a host with no server running are buttons that can
                    // only fail, and the header would have claimed them.
                    if let changed, !changed.files.isEmpty {
                        Button {
                            showDiff = true
                        } label: {
                            Label("Changes (\(changed.files.count))", systemImage: "plus.forwardslash.minus")
                        }
                    }
                    Button {
                        showPreview = true
                    } label: {
                        Label("Browser preview", systemImage: "safari")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showDiff) {
            if let changed { ChatDiffSheet(changed: changed) }
        }
        .sheet(isPresented: $showPreview) {
            PreviewView(client: client)
        }
        .task { await poll() }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let total = transcript.total, total > transcript.messages.count {
                        Text("Showing the last \(transcript.messages.count) of \(total) turns.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(transcript.messages) { message in
                        MessageView(message: message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: transcript.messages.count) { _, _ in
                guard follow else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
        }
    }

    private static let bottom = "chat.bottom"

    /// The first load is awaited by the view; later ones come from the timer.
    private func poll() async {
        await load()
        while !Task.isCancelled {
            try? await Task.sleep(for: refresh)
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func load() async {
        do {
            let next = try await client.transcript(path: path)
            transcript = next
            header = ChatHeader(
                agent: Self.agentName,
                model: ChatHeader.model(in: next.messages),
                session: ChatHeader.session(fromFile: next.file)
            )
            // The changes are fetched with the transcript so the header can name
            // them. A failure here is not the chat's failure — the transcript
            // still reads — so it leaves `changed` nil rather than setting the
            // view's error, which is reserved for the conversation itself.
            changed = try? await client.gitDiff(path: path)
            header.setControls(ChatHeader.controls(fileCount: changed?.files.count, isRepo: changed?.isRepo == true))
            // An error the gateway reported while still returning a page is
            // kept for the empty state and cleared once there is something to
            // show; a stale error over a working view is noise.
            error = next.messages.isEmpty ? next.error : nil
        } catch {
            self.error = "\(error)"
        }
        loading = false
    }
}

/// The working tree's changes, opened from the chat header.
///
/// Deliberately a plain reading rather than the Code tab's diff viewer: that one
/// is built around remembering a reader's place across a long review, and this
/// is a glance at what changed while reading the conversation. The unified diff
/// is shown whole, tinted, with the same `+`/`-` markers the tool cards use.
private struct ChatDiffSheet: View {
    let changed: DiffResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Changed files") {
                    ForEach(changed.files) { file in
                        HStack(spacing: 8) {
                            Text(file.status)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name).font(.callout)
                                if !file.directory.isEmpty {
                                    Text(file.directory)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !changed.diff.isEmpty {
                    Section("Diff") {
                        Text(changed.diff)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// One turn. The voice is carried by the alignment and the label, not by a
/// bubble, because a tool result is not a chat message and a bubble around it
/// would say it was.
private struct MessageView: View {
    let message: AgentMessage
    @Environment(ThemeStore.self) private var themes
    @State private var thinkingOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .padding(.leading, message.role == .user ? 34 : 0)
        .padding(.trailing, message.role == .user ? 0 : 34)
    }

    private var alignment: Alignment { message.role == .user ? .trailing : .leading }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text(label).font(.caption2.weight(.medium))
            if let time = message.date {
                Text(relative(time)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(message.role == .user ? .secondary : themes.current.accentColor)
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    @ViewBuilder
    private func blockView(_ block: AgentBlock) -> some View {
        switch block.kind {
        case .text:
            // Split rather than handed to `Text` whole. A fenced block drawn as
            // prose loses its monospacing and its line breaks, and an inline
            // image is drawn as the literal characters `![alt](url)`; both read
            // as the agent having sent rubbish rather than as the app not
            // having parsed it. What to split on is decided in `ChatMarkdown`.
            InlineText(text: block.displayText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(message.role == .user ? 10 : 0)
                .background(
                    message.role == .user
                    ? themes.current.backgroundColor.opacity(0.55)
                    : .clear,
                    in: RoundedRectangle(cornerRadius: 12)
                )

        case .thinking:
            // Collapsed by default. Reasoning is worth being able to read and
            // not worth scrolling past, and a run that shows its thinking
            // unasked buries the answers.
            DisclosureGroup(isExpanded: $thinkingOpen) {
                Text(block.displayText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Thinking", systemImage: "brain")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .tint(.secondary)

        case .tool:
            ToolCallCard(summary: block.toolSummary, detail: block.input ?? "", isError: false, toolName: block.name)

        case .result:
            ToolCallCard(summary: block.isError == true ? "Failed" : "Result",
                     detail: block.displayText, isError: block.isError == true)

        case .unknown:
            EmptyView()
        }
    }

    private var label: String {
        switch message.role {
        case .user: "You"
        case .assistant: "Agent"
        case .tool: "Tool"
        }
    }

    private var icon: String {
        switch message.role {
        case .user: "person.fill"
        case .assistant: "sparkles"
        case .tool: "terminal"
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// A tool call or its output. Collapsed to one line by default — a session is
/// mostly tool calls, and expanded they would be the whole view.
///
/// Expanded, the card draws the call's *shape* when it has one: an edit as a
/// mini diff, a task list as a checklist, a plan as Markdown. What shape a call
/// is comes from `ToolShape`, and is decided there rather than here because
/// every rule in it fails silently — an unrecognised shape still renders, as
/// JSON, so nothing reports an error and the card merely looks like the wrong
/// thing.
private struct ToolCallCard: View {
    /// The summary line. Doubles as the tool name for shape lookup, because the
    /// transcript only carries the rendered summary, not the raw call.
    let summary: String
    let detail: String
    let isError: Bool
    /// The tool's own name, when a caller has it. Without it the card cannot
    /// classify and shows the detail as it did before — the safe fallback.
    var toolName: String? = nil
    @State private var open = false

    private var shape: ToolShape.Shape {
        guard let toolName else { return .plain }
        return ToolShape.shape(name: toolName, input: detail)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.caption2)
                    Text(collapsedSummary)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                }
                .foregroundStyle(isError ? .orange : .secondary)
            }
            .buttonStyle(.plain)

            if open {
                expanded
            }
        }
    }

    private var symbol: String {
        if isError { return "exclamationmark.triangle" }
        switch shape {
        case .diff: return "plus.forwardslash.minus"
        case .tasks: return "checklist"
        case .plan: return "list.bullet.rectangle"
        case .plain: return "wrench.and.screwdriver"
        }
    }

    /// The collapsed label. A diff says how much changed and to what file — the
    /// two things a reader scans for — rather than dumping the first line of
    /// JSON.
    private var collapsedSummary: String {
        if case .diff(let diff) = shape {
            let file = diff.path.map { ($0 as NSString).lastPathComponent } ?? "file"
            return "\(file)  +\(diff.added) −\(diff.removed)"
        }
        return summary
    }

    @ViewBuilder
    private var expanded: some View {
        switch shape {
        case .diff(let diff):
            MiniDiffView(diff: diff)
        case .tasks(let items):
            TaskListView(items: items)
        case .plan(let text):
            // A plan is Markdown the agent wrote on purpose, so it is rendered
            // through the same splitter the message prose uses rather than
            // shown with its `#` characters intact.
            InlineText(text: text)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        case .plain:
            Text(detail.isEmpty ? "(empty)" : detail)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// A condensed edit: the changed lines, with unchanged context above and below.
private struct MiniDiffView: View {
    let diff: ToolShape.MiniDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path = diff.path {
                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
            }
            // Lines are not wrapped: a wrapped diff line reads as two lines, and
            // the reader cannot tell a long line from an added one.
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 4) {
                            Text(marker(line.kind))
                                .foregroundStyle(color(line.kind))
                            Text(line.text)
                                .foregroundStyle(line.kind == .context ? .secondary : .primary)
                        }
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The diff's own markers. `+`/`-` are what a reader looks for, so they are
    /// the one thing not left to colour alone.
    private func marker(_ kind: ToolShape.DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "-"
        case .context: " "
        }
    }

    private func color(_ kind: ToolShape.DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .context: .secondary
        }
    }
}

/// The agent's task list, as a checklist.
private struct TaskListView: View {
    let items: [ToolShape.TaskItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol(item.status))
                        .font(.caption2)
                        .foregroundStyle(tint(item.status))
                    Text(item.content)
                        .font(.caption)
                        .strikethrough(item.status == .completed)
                        .foregroundStyle(item.status == .completed ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func symbol(_ status: ToolShape.TaskItem.Status) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted"
        case .pending: "circle"
        // Not a checkbox: the agent marked this in a way the app does not know,
        // and drawing it as "not started" would misreport the agent's record.
        case .unknown: "questionmark.circle"
        }
    }

    private func tint(_ status: ToolShape.TaskItem.Status) -> Color {
        switch status {
        case .completed: .green
        case .inProgress: .blue
        case .pending: .secondary
        case .unknown: .orange
        }
    }
}

/// A message's prose, with its code blocks and images drawn as themselves.
///
/// The split itself is `ChatMarkdown`'s job and is checked without a simulator;
/// this only decides how each piece looks. A code block gets monospacing and
/// horizontal scroll — a long line must not be wrapped, because wrapping a
/// command changes what it looks like it does — and an image that cannot be
/// loaded falls back to its alt text rather than an empty box, since the agent
/// describing what it sent is more use than nothing.
private struct InlineText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatMarkdown.segments(in: text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    Text(prose)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .code(let language, let body):
                    VStack(alignment: .leading, spacing: 4) {
                        if let language {
                            Text(language)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(body)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }

                case .image(let url, let alt):
                    InlineImage(url: url, alt: alt)
                }
            }
        }
    }
}

/// One image from a message, or its alt text when it cannot be shown.
private struct InlineImage: View {
    let url: String
    let alt: String

    var body: some View {
        if let link = URL(string: url), link.scheme != nil {
            AsyncImage(url: link) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    fallback
                default:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            // A URL the app cannot even parse is not an image to fetch; the
            // alt text is the whole of what the agent meant.
            fallback
        }
    }

    private var fallback: some View {
        Text(alt.isEmpty ? url : alt)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
