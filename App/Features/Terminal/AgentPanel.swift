import Foundation
import Observation

/// The agent a shortcut panel is for.
///
/// Moshi's panel "adapts to what's running on the host": you get a Ctrl tab, a
/// multiplexer tab, and an agent tab or two "as it detects them on connect".
/// The detection is the host's agent hooks — whatever `cqutmux install` wired
/// up and has since seen events from — which is why the raw `source` string an
/// event carries is what the panel is keyed on rather than a display name.
///
/// The `source` values are the ones `host/cqutmux-hook/agent-hook.mjs` sends.
/// An agent we have no panel for is deliberately not shown rather than shown
/// empty: a tab of buttons that do nothing is worse than no tab.
enum AgentKind: String, CaseIterable, Codable, Identifiable {
    case claudeCode = "claude-code"
    case codex = "codex"
    case cursor = "cursor"

    var id: String { rawValue }

    /// What the tab is called. Short, because it sits in a segmented row
    /// beside the multiplexer's tab and possibly another agent's.
    var label: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    /// The `source` strings the host uses for this agent. A set rather than one
    /// value because the same agent can arrive under more than one spelling —
    /// `claude-code` from the hook we install, and older events under `claude`.
    var sources: Set<String> {
        switch self {
        case .claudeCode: ["claude-code", "claude"]
        case .codex: ["codex"]
        case .cursor: ["cursor"]
        }
    }

    /// The agent a hook `source` names, or nil when it is one we have no panel
    /// for (kimi-code, antigravity, an agent added later).
    static func detected(fromSource source: String) -> AgentKind? {
        let lower = source.lowercased()
        return allCases.first { $0.sources.contains(lower) }
    }
}

/// One button in an agent's panel.
///
/// A command is either a *line to run* (`/clear` and Return) or *keys to send*
/// (⇧Tab). The distinction is not cosmetic: a slash command typed into a live
/// shell is a path, not a command, and the whole point of the panel is that the
/// user does not have to know which they are looking at. `sends` is the raw
/// shortcut text `ShortcutGrammar` already parses — `text:/clear` for the one,
/// `S-Tab` for the other — so a button and a user's own custom shortcut take the
/// same path to the wire.
struct AgentCommand: Identifiable, Codable, Hashable {
    var id: String
    /// What the button shows. The command itself for a slash command, since
    /// that is what the user recognises.
    var label: String
    /// A one-line explanation, shown under the label where there is room. Moshi
    /// gives each button one ("Reset conversation", "Shrink context"), and a
    /// row of bare slash commands is guesswork for anyone who has not memorised
    /// them.
    var detail: String
    /// The shortcut text this sends, in the grammar `ShortcutGrammar` parses.
    /// `text:…` carries its own Return; `S-Tab` sends CSI-Z.
    var sends: String

    /// The bytes, or nil when the text no longer parses — the same
    /// keep-and-flag rule `CustomShortcut` follows, so a grammar change cannot
    /// silently empty a button.
    var bytes: [UInt8]? { (try? ShortcutGrammar.parse(sends))?.bytes }

    var problem: String? {
        do {
            _ = try ShortcutGrammar.parse(sends)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The buttons Moshi ships for each agent, before any user editing.
///
/// Kept as a pure table so the defaults can be checked against the documentation
/// without a simulator — the failure this guards is a button that sends the
/// wrong thing, which looks identical to one that works until it is pressed.
enum AgentPanel {
    /// The buttons for `agent`, in the order the docs list them.
    static func defaults(for agent: AgentKind) -> [AgentCommand] {
        switch agent {
        case .claudeCode:
            // The keyboard-guide page gives this list verbatim, with the action
            // each one takes. `/help` is included because both Moshi pages list
            // it even though the claude-code guide omits it.
            return [
                AgentCommand(id: "shift-tab", label: "⇧Tab", detail: "Cycle permission modes",
                             sends: "S-Tab"),
                AgentCommand(id: "clear", label: "/clear", detail: "Reset conversation",
                             sends: "text:/clear"),
                AgentCommand(id: "compact", label: "/compact", detail: "Shrink context",
                             sends: "text:/compact"),
                AgentCommand(id: "resume", label: "/resume", detail: "Continue previous session",
                             sends: "text:/resume"),
                AgentCommand(id: "model", label: "/model", detail: "Switch models mid-session",
                             sends: "text:/model"),
                AgentCommand(id: "permissions", label: "/permissions",
                             detail: "Review what Claude may do without asking",
                             sends: "text:/permissions"),
                AgentCommand(id: "usage", label: "/usage",
                             detail: "Check rate-limit windows",
                             sends: "text:/usage"),
                AgentCommand(id: "memory", label: "/memory", detail: "View context",
                             sends: "text:/memory"),
                AgentCommand(id: "tasks", label: "/tasks", detail: "Show todos",
                             sends: "text:/tasks"),
                AgentCommand(id: "config", label: "/config", detail: "Open settings",
                             sends: "text:/config"),
                AgentCommand(id: "help", label: "/help", detail: "Show help",
                             sends: "text:/help"),
            ]
        case .codex:
            // Moshi documents a Codex panel as existing ("panels for … Codex")
            // but not its buttons; the Codex guide lists these slash commands
            // for the CLI. Recorded as our reading of the CLI, not a verbatim
            // Moshi panel — see PLAN.md.
            return [
                AgentCommand(id: "new", label: "/new", detail: "Start a new conversation",
                             sends: "text:/new"),
                AgentCommand(id: "resume", label: "/resume", detail: "Continue a session",
                             sends: "text:/resume"),
                AgentCommand(id: "compact", label: "/compact", detail: "Shrink context",
                             sends: "text:/compact"),
                AgentCommand(id: "model", label: "/model", detail: "Switch models",
                             sends: "text:/model"),
                AgentCommand(id: "permissions", label: "/permissions",
                             detail: "Review what Codex may do", sends: "text:/permissions"),
                AgentCommand(id: "plan", label: "/plan", detail: "Plan mode",
                             sends: "text:/plan"),
                AgentCommand(id: "diff", label: "/diff", detail: "Show pending changes",
                             sends: "text:/diff"),
                AgentCommand(id: "status", label: "/status", detail: "Session status",
                             sends: "text:/status"),
            ]
        case .cursor:
            // Moshi *does* ship a Cursor panel — the keyboard guide says so
            // ("Moshi ships matching Codex and Cursor CLI panels too"). What it
            // does not publish is the list, and guesses are worse here than
            // elsewhere: a wrong slash command in Claude or Codex is at least a
            // command those CLIs recognise, while Cursor's CLI we have no
            // reference for at all. So the panel ships empty and the UI says so
            // in as many words, with an Add button — a visibly unfinished tab is
            // honest, a manufactured one is not.
            return []
        }
    }
}

/// The panel for one agent as this user has it: the defaults, reordered,
/// removed or extended, and persisted.
///
/// Mirrors `ShortcutStore` and `GestureStore` on purpose — same shape, same
/// keep-the-raw-text rule, same injectable `UserDefaults` so a check does not
/// edit the settings of whoever runs it. A panel that drifts from those two
/// stores in how it round-trips is a third convention to learn.
@Observable
final class AgentPanelStore {
    private let defaults: UserDefaults
    private static let key = "cqutmux.agentPanels"

    /// The user's own buttons per agent, once they have touched them. An agent
    /// with no entry has never been edited and uses `AgentPanel.defaults`.
    private var custom: [String: [AgentCommand]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// The buttons to show for `agent`, defaults or the user's edit of them.
    func commands(for agent: AgentKind) -> [AgentCommand] {
        custom[agent.rawValue] ?? AgentPanel.defaults(for: agent)
    }

    /// Whether this agent's panel has been edited away from the defaults.
    func isCustomised(_ agent: AgentKind) -> Bool {
        guard let edited = custom[agent.rawValue] else { return false }
        return edited != AgentPanel.defaults(for: agent)
    }

    /// Replaces an agent's panel, as an edit does.
    func setCommands(_ commands: [AgentCommand], for agent: AgentKind) {
        custom[agent.rawValue] = commands
        save()
    }

    /// Removes one button.
    func remove(_ command: AgentCommand, from agent: AgentKind) {
        var current = commands(for: agent)
        current.removeAll { $0.id == command.id }
        setCommands(current, for: agent)
    }

    func move(from source: IndexSet, to destination: Int, in agent: AgentKind) {
        var current = commands(for: agent)
        // Written out rather than using SwiftUI's `move(fromOffsets:toOffset:)`
        // so this file stays Foundation-only and can be compiled on its own by a
        // headless check — the property the whole "pure model, checked apart
        // from the view" split depends on. `ShortcutStore` can use the SwiftUI
        // one because nothing compiles it standalone; this one is checked.
        let moving = source.map { current[$0] }
        for index in source.sorted(by: >) { current.remove(at: index) }
        // The destination counts against the *old* positions, so it shifts down
        // by however many of the moved items sat in front of it.
        let adjusted = destination - source.filter { $0 < destination }.count
        current.insert(contentsOf: moving, at: max(0, min(adjusted, current.count)))
        setCommands(current, for: agent)
    }

    /// Adds a user button, whose `sends` they type themselves.
    func add(_ command: AgentCommand, to agent: AgentKind) {
        var current = commands(for: agent)
        current.append(command)
        setCommands(current, for: agent)
    }

    /// Back to the shipped defaults. The per-agent counterpart to
    /// `ShortcutStore.resetAll` — removing an agent's entry is what "restore"
    /// means, since the defaults are not stored.
    func reset(_ agent: AgentKind) {
        custom.removeValue(forKey: agent.rawValue)
        save()
    }

    func resetAll() {
        custom.removeAll()
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([String: [AgentCommand]].self, from: data)
        else { return }
        custom = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(custom) else { return }
        defaults.set(data, forKey: Self.key)
    }
}