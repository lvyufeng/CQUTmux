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

    /// Reading the log on a timer rather than being pushed to. The log is a
    /// file the agent appends to; there is no event to subscribe to, and a
    /// poll of a local file is cheap enough that a stream would be complexity
    /// for its own sake. Three seconds is short enough to feel live while a
    /// turn is running and long enough not to matter when it is not.
    private let refresh = Duration.seconds(3)

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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
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
            ToolCard(summary: block.toolSummary, detail: block.input ?? "", isError: false)

        case .result:
            ToolCard(summary: block.isError == true ? "Failed" : "Result",
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
private struct ToolCard: View {
    let summary: String
    let detail: String
    let isError: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                        .font(.caption2)
                    Text(summary)
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
                Text(detail.isEmpty ? "(empty)" : detail)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
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
