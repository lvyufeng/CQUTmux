import SwiftUI

/// One tappable row in the shortcut panel, uniform across its pages.
///
/// The agent pages come from `AgentPanelStore`, but Ctrl and the multiplexer
/// are neither the user's to edit nor agent-specific, so the view carries its
/// own small row type rather than forcing every page through a store that is
/// keyed on an `AgentKind`.
struct PanelButton: Identifiable {
    var id: String
    var label: String
    /// The one-line explanation under the label. A row of bare slash commands
    /// is guesswork for anyone who has not memorised them.
    var detail: String
    /// A parsed shortcut, which is the preferred send: `CQUTTerminalView.send`
    /// paces a multi-step one. Nil for the multiplexer chords, which the
    /// grammar cannot express — their prefix is a setting, not part of the
    /// shortcut text.
    var parsed: ShortcutGrammar.Parsed?
    /// Bytes for a button with no shortcut text behind it.
    var raw: [UInt8]?
    /// Why this button cannot send, when it cannot. Shown rather than hidden,
    /// matching `CustomShortcut`.
    var problem: String?

    /// Whether a tap sends anything. A button with a problem is deliberately
    /// not disabled — it has to stay long-pressable so it can be edited or
    /// removed — so the tap itself is what declines, the same way a broken
    /// custom key does.
    var canSend: Bool { problem == nil && (parsed != nil || raw != nil) }
}

/// What a tap on a panel button sends: a parsed shortcut, so it takes the same
/// paced path a custom key does, or raw bytes for a mux chord.
enum PanelSend {
    case shortcut(ShortcutGrammar.Parsed)
    case bytes([UInt8])
}

/// The panel's built-in pages and the source detection behind its agent tabs.
///
/// Kept apart from the view for the same reason `AgentPanel` is: what a button
/// sends is the part that fails silently, and it is cheapest to reason about
/// (and, later, to check) without a simulator.
enum AgentPanelPages {
    /// Which agents this session involves, in `AgentKind.allCases` order.
    ///
    /// Keyed on the raw `source` string an event carries rather than a display
    /// name, because that is what the host's hook sends. An agent we have no
    /// panel for — kimi-code, antigravity — is deliberately absent rather than
    /// present and empty: a tab of buttons that do nothing is worse than no tab.
    /// An agent with a *documented but empty* panel (Cursor) is a different
    /// case and does appear, because the tab is real and the emptiness is the
    /// honest answer.
    static func detect(fromSources sources: [String]) -> [AgentKind] {
        AgentKind.allCases.filter { kind in
            sources.contains { kind.sources.contains($0.lowercased()) }
        }
    }

    /// The Ctrl page: the control keys a terminal is used through.
    ///
    /// Not transcribed from a Moshi table — the docs describe a Ctrl tab but do
    /// not enumerate it — so these are the standard readline and terminal
    /// controls, labelled by what they do rather than by the keystroke, which
    /// is the whole point of the panel. They are written as `ShortcutGrammar`
    /// text so a tap takes the same `send(_:)` path (and pacing) as every other
    /// button, and so a grammar change could not leave one of them unrunnable
    /// without the panel flagging it.
    static func controlButtons() -> [PanelButton] {
        [
            shortcut("C-c", "Ctrl-C", "Interrupt the foreground job"),
            shortcut("C-d", "Ctrl-D", "End input — logs out an empty shell"),
            shortcut("C-z", "Ctrl-Z", "Suspend the foreground job"),
            shortcut("C-l", "Ctrl-L", "Clear the screen"),
            shortcut("C-r", "Ctrl-R", "Search the command history"),
            shortcut("C-a", "Ctrl-A", "Jump to the start of the line"),
            shortcut("C-e", "Ctrl-E", "Jump to the end of the line"),
            shortcut("C-u", "Ctrl-U", "Delete back to the start of the line"),
            shortcut("C-k", "Ctrl-K", "Delete forward to the end of the line"),
            shortcut("C-w", "Ctrl-W", "Delete the word before the cursor"),
            shortcut("C-b", "Ctrl-B", "Move the cursor back one character"),
            shortcut("C-f", "Ctrl-F", "Move the cursor forward one character"),
        ]
    }

    /// The multiplexer page: one button per key this client knows how to send
    /// the host's mux, restricted to the ones that mux actually binds.
    ///
    /// Empty on a host with no multiplexer, which is also why the page itself
    /// is only offered when there is one — a page of chords the host has no
    /// binding for would type stray control characters into whatever is
    /// running. Bytes rather than shortcut text because the prefix is a
    /// setting (`MuxSettings.Prefix`), not part of the grammar.
    static func muxButtons(mux: String?, prefix: MuxSettings.Prefix) -> [PanelButton] {
        MuxSettings.MuxCommand.allCases.compactMap { command in
            guard let bytes = command.bytes(prefix: prefix, mux: mux) else { return nil }
            return PanelButton(
                id: command.rawValue,
                label: command.label,
                detail: chord(bytes, prefix: prefix),
                parsed: nil,
                raw: bytes,
                problem: nil
            )
        }
    }

    /// A one-line description of the keys a mux command sends, for the
    /// button's subtitle: `prefix n` for the keyed chords, the literal line for
    /// the `zellij action` forms.
    private static func chord(_ bytes: [UInt8], prefix: MuxSettings.Prefix) -> String {
        let head = prefix.bytes
        if bytes.count == head.count + 1, Array(bytes.prefix(head.count)) == head,
           let last = bytes.last, last >= 0x20, last < 0x7F {
            return "\(prefix.label) \(Character(UnicodeScalar(last)))"
        }
        if let text = String(bytes: bytes, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func shortcut(_ sends: String, _ label: String, _ detail: String) -> PanelButton {
        let parsed = try? ShortcutGrammar.parse(sends)
        return PanelButton(
            id: sends, label: label, detail: detail,
            parsed: parsed, raw: nil,
            problem: parsed == nil ? "“\(sends)” no longer parses." : nil
        )
    }
}

/// The shortcut panel: a Ctrl tab, a multiplexer tab, and one tab per agent the
/// session is running. Opened by long-pressing the terminal's Ctrl key, or from
/// the `.agentPanel` bar item.
struct AgentPanelBar: View {
    /// The agents detected in this session, already deduped and ordered.
    let agents: [AgentKind]
    /// This session's multiplexer, or nil for a plain shell.
    let mux: String?
    let prefix: MuxSettings.Prefix
    let store: AgentPanelStore
    let onSend: (PanelSend) -> Void
    /// Closes the panel. A closure rather than `@Environment(\.dismiss)`: the
    /// panel is an overlay on the session, not a presented sheet, so there is
    /// no dismissal for the environment to reach and the Done button would do
    /// nothing.
    let onDone: () -> Void

    @State private var page: Page = .control
    @State private var editing: EditTarget?

    private enum Page: Hashable, Identifiable {
        case control
        case mux
        case agent(AgentKind)

        var id: String {
            switch self {
            case .control: "control"
            case .mux: "mux"
            case .agent(let kind): "agent-\(kind.rawValue)"
            }
        }

        /// Short, because it sits in a segmented row beside the others.
        var title: String {
            switch self {
            case .control: "Ctrl"
            case .mux: "Mux"
            case .agent(let kind): kind.label
            }
        }
    }

    /// The agent's own button being edited, or nil for a new one.
    private struct EditTarget: Identifiable {
        let id = UUID()
        let agent: AgentKind
        let command: AgentCommand?
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    /// Ctrl first, then the multiplexer, then the agents — the order the panel
    /// reads from "keys everyone has" to "the tools running in this session".
    private var pages: [Page] {
        var out: [Page] = [.control]
        if mux != nil { out.append(.mux) }
        out.append(contentsOf: agents.map(Page.agent))
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            // Hidden for a single page: a segmented control with one segment is
            // a control that does nothing.
            if pages.count > 1 {
                Picker("Page", selection: $page) {
                    ForEach(pages) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            ScrollView { content }
        }
        .navigationTitle("Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onDone() }
            }
        }
        .onAppear {
            // Open on the first agent when there is one: the panel is reached
            // from a session the agent is running in, so its own buttons are
            // what the tap was for. Ctrl is the fallback, not the destination.
            if let first = agents.first { page = .agent(first) } else { page = pages[0] }
        }
        .sheet(item: $editing) { target in
            NavigationStack {
                AgentButtonEditor(agent: target.agent, store: store, original: target.command)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .control:
            grid(AgentPanelPages.controlButtons(), agent: nil)
        case .mux:
            grid(AgentPanelPages.muxButtons(mux: mux, prefix: prefix), agent: nil)
        case .agent(let kind):
            agentPage(kind)
        }
    }

    @ViewBuilder
    private func agentPage(_ kind: AgentKind) -> some View {
        let commands = store.commands(for: kind)
        VStack(spacing: 10) {
            if commands.isEmpty {
                // Shown empty rather than hidden: an agent with no buttons is a
                // fact about the session, and a missing tab would read as the
                // app having failed to notice the agent at all. The way to fill
                // it is the button below.
                Text("No buttons for \(kind.label) yet. Moshi ships a panel but "
                     + "does not publish its buttons, and a made-up shortcut "
                     + "is worse than none — add your own below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 24)
            } else {
                grid(commands.map(button(from:)), agent: kind)
            }
            addButton(kind)
            if store.isCustomised(kind) { resetButton(kind) }
        }
    }

    private func grid(_ buttons: [PanelButton], agent: AgentKind?) -> some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(buttons) { button in
                cell(button, agent: agent)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private func cell(_ button: PanelButton, agent: AgentKind?) -> some View {
        Button { send(button) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(button.label)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                if !button.detail.isEmpty {
                    Text(button.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .tint(button.problem == nil ? nil : .orange)
        .accessibilityHint(button.problem ?? button.detail)
        // Long press edits or removes the button, which is how Moshi puts it.
        // Only agent pages: the Ctrl and multiplexer pages are built in, and
        // there is no store that could hold an edit to them.
        .onLongPressGesture(minimumDuration: 0.4) {
            guard let agent,
                  let command = store.commands(for: agent).first(where: { $0.id == button.id })
            else { return }
            editing = EditTarget(agent: agent, command: command)
        }
    }

    private func addButton(_ kind: AgentKind) -> some View {
        Button {
            editing = EditTarget(agent: kind, command: nil)
        } label: {
            Label("Add a button", systemImage: "plus")
                .font(.callout)
        }
        .buttonStyle(.bordered)
        .padding(.top, 4)
    }

    private func resetButton(_ kind: AgentKind) -> some View {
        Button("Reset \(kind.label)'s buttons", role: .destructive) {
            store.reset(kind)
        }
        .font(.footnote)
    }

    private func send(_ button: PanelButton) {
        guard button.canSend else { return }
        if let parsed = button.parsed {
            onSend(.shortcut(parsed))
        } else if let raw = button.raw {
            onSend(.bytes(raw))
        }
    }

    /// An `AgentCommand` as a panel row. The parsed form is what gets sent, so a
    /// `text:` button keeps its Return and a multi-step one keeps its pacing.
    private func button(from command: AgentCommand) -> PanelButton {
        PanelButton(
            id: command.id,
            label: command.label,
            detail: command.detail,
            parsed: try? ShortcutGrammar.parse(command.sends),
            raw: nil,
            problem: command.problem
        )
    }
}

/// Adds, edits, or removes one agent button. The same shape as
/// `EditShortcutView`: a raw shortcut string the user types, with a live
/// preview so an error arrives before saving rather than as a button that
/// quietly does nothing.
private struct AgentButtonEditor: View {
    let agent: AgentKind
    let store: AgentPanelStore
    /// The button being edited, or nil when adding.
    let original: AgentCommand?

    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var detail: String
    @State private var sends: String

    init(agent: AgentKind, store: AgentPanelStore, original: AgentCommand?) {
        self.agent = agent
        self.store = store
        self.original = original
        _label = State(initialValue: original?.label ?? "")
        _detail = State(initialValue: original?.detail ?? "")
        _sends = State(initialValue: original?.sends ?? "")
    }

    private var problem: String? {
        AgentCommand(id: "draft", label: label, detail: detail, sends: sends).problem
    }

    var body: some View {
        Form {
            Section("Button") {
                TextField("Label", text: $label)
                TextField("Detail (optional)", text: $detail)
            }
            Section {
                TextField("text:/clear", text: $sends)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Sends")
            } footer: {
                Text("The same grammar as a custom key: `text:/clear` sends the line "
                     + "and Return, `S-Tab` sends ⇧Tab. Modifiers: C-, M-/Opt-, S-.")
                    .font(.caption)
            }

            Section("Preview") {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if let parsed = try? ShortcutGrammar.parse(sends) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(parsed.label)
                            .font(.system(.body, design: .monospaced))
                        Text(parsed.steps.map { $0.bytes.map(byteName).joined(separator: " ") }
                            .joined(separator: "  ·  "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if parsed.autoEnter {
                            Text("Followed by Return")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if original != nil {
                Section {
                    Button("Remove this button", role: .destructive) {
                        if let original { store.remove(original, from: agent) }
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(original == nil ? "Add Button" : "Edit Button")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || problem != nil)
            }
        }
    }

    private func save() {
        let command = AgentCommand(
            // A new button's id is generated once and carried, so re-saving an
            // edit does not change it and the row does not lose its identity to
            // SwiftUI's `ForEach`.
            id: original?.id ?? "custom-\(UUID().uuidString)",
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines),
            sends: sends.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var current = store.commands(for: agent)
        if let original, let index = current.firstIndex(where: { $0.id == original.id }) {
            current[index] = command
        } else {
            current.append(command)
        }
        store.setCommands(current, for: agent)
        dismiss()
    }

    private func byteName(_ byte: UInt8) -> String {
        switch byte {
        case 0x1B: return "ESC"
        case 0x0D: return "CR"
        case 0x20...0x7E: return String(UnicodeScalar(byte))
        default: return String(format: "0x%02X", byte)
        }
    }
}