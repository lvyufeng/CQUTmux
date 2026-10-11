import Foundation

// Checks the agent command panel's model layer — the button table, the source
// detection, and the store that edits and persists them.
//
// Every failure this guards is silent on a device. A button that sends the
// wrong bytes looks exactly like one that works until it is pressed, and the
// wrong bytes go into a live agent session with a user's context in it. A
// duplicated id drops rows out of a SwiftUI `ForEach` with no error. An
// off-by-one in the reorder logic moves the wrong button and the list still
// looks plausible. None of these announce themselves, so the only cheap way to
// catch them is here, without a simulator.
//
// This compiles `AgentPanel.swift` and `ShortcutGrammar.swift` straight from
// the app target with `swiftc`. `AgentPanel` is Foundation + Observation only
// precisely so that this works.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)")
    }
}

/// Compares two byte arrays, reporting which side is which when they differ —
/// a raw `==` failure on `[UInt8]` prints two integer lists nobody reads.
func checkBytes(_ got: [UInt8]?, _ want: [UInt8], _ label: String) {
    let pass = got == want
    checks += 1
    if pass {
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)")
        print("        got  \(got.map { $0.map { String(format: "%02X", $0) } } ?? ["<nil>"])")
        print("        want \(want.map { String(format: "%02X", $0) })")
    }
}

// MARK: - The default button table

// The three fixed points the docs pin. These were chosen because a wrong value
// here is invisible until a real agent is at the prompt: ⇧Tab in particular is
// read by Claude Code to cycle permission modes, and a near-miss (a plain Tab,
// or an ESC-[ that is missing its final byte) is a keystroke the agent quietly
// ignores or misreads.

let claude = AgentPanel.defaults(for: .claudeCode)

let shiftTab = claude.first { $0.id == "shift-tab" }
check(shiftTab != nil, "the Claude panel has a ⇧Tab button")
check(shiftTab?.sends == "S-Tab", "⇧Tab sends the S-Tab shortcut, not a literal tab")
checkBytes(shiftTab?.bytes, [0x1B, 0x5B, 0x5A],
           "⇧Tab's bytes are CSI-Z (ESC [ Z), which is what the wire carries")
check(shiftTab?.problem == nil, "⇧Tab parses, so it is not flagged as broken")

let clear = claude.first { $0.id == "clear" }
check(clear != nil, "the Claude panel has a /clear button")
check(clear?.sends == "text:/clear",
      "/clear is a text: shortcut, so it runs as a command rather than typing a path")
check(clear?.problem == nil, "/clear parses")

// The whole point of `text:` is that it carries its own Return. If the CR were
// absent the command would sit unsubmitted at the prompt, which reads as "the
// button did nothing"; if a stray byte crept in, the agent would receive mangled
// input.
checkBytes(clear?.bytes, Array("/clear".utf8) + [0x0D],
           "/clear's bytes are exactly its ASCII plus one CR")

// A `text:` button must never advertise a control sequence — it is a line to
// run, not keys to send, and the two must not be confused.
check((clear?.bytes ?? []).first == UInt8(ascii: "/"),
      "/clear starts with the slash, not a control byte")

// Every default button must parse. A button whose `sends` no longer compiles is
// one the panel shows but cannot fire, and `problem` is the only thing that
// would say so — so pin that none of them carry one.
for agent in AgentKind.allCases {
    let broken = AgentPanel.defaults(for: agent).filter { $0.problem != nil }
    check(broken.isEmpty,
          "every default button for \(agent.rawValue) parses without a problem")
}

// MARK: - The ids are unique

// A duplicate id makes SwiftUI's `ForEach` collapse or drop rows with no error
// at all: the panel just comes up a button short. The user cannot tell that the
// app is at fault, so it has to be caught here.
for agent in AgentKind.allCases {
    let ids = AgentPanel.defaults(for: agent).map(\.id)
    check(Set(ids).count == ids.count,
          "the \(agent.rawValue) panel has no duplicate button ids")
}

// MARK: - Cursor is empty on purpose

// Cursor has no documented panel and no documented slash set. Empty is the
// honest answer — an invented button is worse than none, because it looks like
// it works. This is asserted rather than left implicit so that a later change
// adding speculative buttons fails here and has to justify itself.
check(AgentPanel.defaults(for: .cursor).isEmpty,
      "Cursor's panel is empty, because Moshi documents no buttons for it")

// MARK: - Source detection

// The panel is keyed on the raw `source` string the host hook sends, so what an
// agent answers to is the contract — not its display name.
check(AgentKind.detected(fromSource: "claude-code") == .claudeCode,
      "\"claude-code\" is the Claude panel")
check(AgentKind.detected(fromSource: "codex") == .codex,
      "\"codex\" is the Codex panel")
check(AgentKind.detected(fromSource: "cursor") == .cursor,
      "\"cursor\" is the Cursor panel")
// An agent we have no panel for must come back nil so the tab is not shown at
// all. A tab of buttons that do nothing is worse than no tab.
check(AgentKind.detected(fromSource: "kimi-code") == nil,
      "an agent with no panel is not shown rather than shown empty")
check(AgentKind.detected(fromSource: "antigravity") == nil,
      "and neither is one that does not exist yet")
check(AgentKind.detected(fromSource: "") == nil, "an empty source names no agent")

// The host decides the casing; the panel must not depend on it.
check(AgentKind.detected(fromSource: "Claude-Code") == .claudeCode,
      "detection is case-insensitive")
check(AgentKind.detected(fromSource: "CODEX") == .codex,
      "in every spelling")
// The older spelling Claude events arrive under, which is why `sources` is a
// set rather than one value.
check(AgentKind.detected(fromSource: "claude") == .claudeCode,
      "the older \"claude\" source still finds the Claude panel")

// MARK: - The store round-trips, on a scratch suite

// A scratch suite, so a check run can never read or write the settings of
// whoever runs it. Fresh each run so one run's leftovers cannot pass the next.
let suiteName = "cqutmux.agentpanel-check.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }

let store = AgentPanelStore(defaults: defaults)

check(store.commands(for: .claudeCode) == AgentPanel.defaults(for: .claudeCode),
      "an untouched store hands back the shipped defaults")
check(!store.isCustomised(.claudeCode), "and reports itself un-customised")

// remove
store.remove(clear!, from: .claudeCode)
let afterRemove = store.commands(for: .claudeCode)
check(!afterRemove.contains { $0.id == "clear" }, "remove drops the button")
check(afterRemove.count == claude.count - 1, "and drops exactly one")
check(store.isCustomised(.claudeCode), "removing a button marks the panel customised")
check(AgentPanelStore(defaults: defaults).commands(for: .claudeCode) == afterRemove,
      "the removal is persisted")

// reset restores the defaults and clears the customised flag
store.reset(.claudeCode)
check(store.commands(for: .claudeCode) == AgentPanel.defaults(for: .claudeCode),
      "reset restores the shipped defaults")
check(!store.isCustomised(.claudeCode), "and clears the customised flag")
check(AgentPanelStore(defaults: defaults).commands(for: .claudeCode)
        == AgentPanel.defaults(for: .claudeCode),
      "resetting one agent persists too")

// add appends a user button, whose sends they type themselves
let custom = AgentCommand(id: "mine", label: "/mine", detail: "My button",
                          sends: "text:/mine")
store.add(custom, to: .codex)
let afterAdd = store.commands(for: .codex)
check(afterAdd.last == custom, "add appends the button at the end")
check(afterAdd.count == AgentPanel.defaults(for: .codex).count + 1,
      "and adds exactly one")
check(store.isCustomised(.codex), "adding marks the panel customised")

// Adding to one agent must not disturb another — the two panels are separate.
check(store.commands(for: .claudeCode) == AgentPanel.defaults(for: .claudeCode),
      "editing one agent leaves the other alone")

// MARK: - Reordering

// The insert index is computed by hand, so it is the piece most likely to be an
// off-by-one. Both directions are checked against the exact expected order, not
// just "something moved".
let ids = claude.map(\.id)
let first = ids[0]
let last = ids[ids.count - 1]

// Front to back: the first button ends up last, everything else slides up one.
store.setCommands(claude, for: .claudeCode)
store.move(from: IndexSet(integer: 0), to: claude.count, in: .claudeCode)
let movedFrontToBack = store.commands(for: .claudeCode).map(\.id)
check(movedFrontToBack == Array(ids.dropFirst()) + [first],
      "moving the first button to the end puts it last and keeps the rest in order")

// Back to front: the last button ends up first. Reset first, so this asserts
// against the shipped order rather than whatever the previous move left behind.
store.setCommands(claude, for: .claudeCode)
store.move(from: IndexSet(integer: claude.count - 1), to: 0, in: .claudeCode)
let movedBackToFront = store.commands(for: .claudeCode).map(\.id)
check(movedBackToFront == [last] + Array(ids.dropLast()),
      "moving the last button to the front puts it first")

// A middle move, where the destination-shift arithmetic actually bites: with a
// destination past the source, the naive insert lands one slot late.
store.setCommands(claude, for: .claudeCode)
store.move(from: IndexSet(integer: 1), to: 4, in: .claudeCode)
var expectedMiddle = ids
let dragged = expectedMiddle.remove(at: 1)          // index 1 → the first "to: N" no longer shifts
expectedMiddle.insert(dragged, at: 3)               // destination 4 counts old positions
check(store.commands(for: .claudeCode).map(\.id) == expectedMiddle,
      "a mid-list move respects the adjusted insert index")

// A move to the very end and back must be a round trip, or the two directions
// disagree about where "the end" is.
store.setCommands(claude, for: .claudeCode)
store.move(from: IndexSet(integer: 0), to: claude.count, in: .claudeCode)
store.move(from: IndexSet(integer: claude.count - 1), to: 0, in: .claudeCode)
check(store.commands(for: .claudeCode).map(\.id) == ids,
      "out and back leaves the order unchanged")

// A no-op move (drop a button back where it started) must not silently shuffle
// anything, which is the failure a SwiftUI drag produces every time a finger
// lifts on the row it picked up.
store.setCommands(claude, for: .claudeCode)
store.move(from: IndexSet(integer: 2), to: 2, in: .claudeCode)
check(store.commands(for: .claudeCode).map(\.id) == ids,
      "a move that does not move changes nothing")

// MARK: - Reset-all spans every agent

store.resetAll()
for agent in AgentKind.allCases {
    check(store.commands(for: agent) == AgentPanel.defaults(for: agent),
          "resetAll restores \(agent.rawValue) to its defaults")
    check(!store.isCustomised(agent),
          "and clears \(agent.rawValue)'s customised flag")
}

// MARK: - Corrupted storage degrades, it does not crash

// The stored blob is JSON the user's backup or an older build could have
// mangled. The honest answer is to show the shipped defaults, not to crash and
// not to show a decoding error nobody can act on.
defaults.set(Data("not json at all".utf8), forKey: "cqutmux.agentPanels")
check(AgentPanelStore(defaults: defaults).commands(for: .claudeCode)
        == AgentPanel.defaults(for: .claudeCode),
      "unreadable stored panels degrade to the defaults rather than crashing")

// Valid JSON of the wrong shape must also fall back, not throw halfway.
defaults.set(Data("[1,2,3]".utf8), forKey: "cqutmux.agentPanels")
check(AgentPanelStore(defaults: defaults).commands(for: .codex)
        == AgentPanel.defaults(for: .codex),
      "a stored blob of the wrong shape also degrades to the defaults")

// MARK: - The grammar underneath is unchanged

// The panel rides on `ShortcutGrammar`, so the two facts its buttons depend on
// are pinned here: `S-Tab` is CSI-Z (this file's own recent fix), and `text:`
// carries autoEnter so a slash command runs.
if let parsedShiftTab = try? ShortcutGrammar.parse("S-Tab") {
    check(parsedShiftTab.bytes == [0x1B, 0x5B, 0x5A], "S-Tab parses to CSI-Z")
    check(!parsedShiftTab.autoEnter, "S-Tab does not append a Return")
} else {
    check(false, "S-Tab parses at all")
}

if let parsedClear = try? ShortcutGrammar.parse("text:/clear") {
    check(parsedClear.autoEnter, "text:/clear sets autoEnter")
    check(parsedClear.bytes.last == 0x0D, "so its last byte is a Return")
    check(parsedClear.label == "/clear", "and it labels itself as the command it types")
} else {
    check(false, "text:/clear parses at all")
}

// MARK: - The Ctrl page's bytes, one by one

// `AgentPanelPages.controlButtons` is the panel's own reading of a Ctrl tab —
// Moshi's docs describe the tab but do not enumerate it — so the only thing
// that can prove it right is the readline/terminal table it claims to be. Each
// control byte is `key & 0x1F`, and a near miss (0x03 vs 0x04, Ctrl-C vs
// Ctrl-D) is two different signals into a live session: one interrupts the job,
// the other closes the shell. So every button is pinned to its exact byte, and
// the whole set is pinned to "these twelve and no others" so a button cannot be
// dropped or added without this failing.
let controls = AgentPanelPages.controlButtons()

let expectedControls: [(id: String, label: String, byte: UInt8)] = [
    ("C-c", "Ctrl-C", 0x03), ("C-d", "Ctrl-D", 0x04), ("C-z", "Ctrl-Z", 0x1A),
    ("C-l", "Ctrl-L", 0x0C), ("C-r", "Ctrl-R", 0x12), ("C-a", "Ctrl-A", 0x01),
    ("C-e", "Ctrl-E", 0x05), ("C-u", "Ctrl-U", 0x15), ("C-k", "Ctrl-K", 0x0B),
    ("C-w", "Ctrl-W", 0x17), ("C-b", "Ctrl-B", 0x02), ("C-f", "Ctrl-F", 0x06),
]

check(controls.count == expectedControls.count,
      "the Ctrl page is exactly the twelve standard readline controls")
check(controls.map(\.id) == expectedControls.map(\.id),
      "the Ctrl page lists exactly these controls, in this order")

for (id, label, byte) in expectedControls {
    let button = controls.first { $0.id == id }
    check(button != nil, "the Ctrl page has a \(label) button")
    check(button?.label == label, "\(label)'s label is \(label), not the raw shortcut")
    check(button?.detail.isEmpty == false, "\(label) explains what it does")
    check(button?.problem == nil, "\(label) parses without a problem")
    checkBytes(button?.parsed?.bytes, [byte],
               "\(label) sends exactly 0x\(String(format: "%02X", byte))")
    check(button?.raw == nil, "\(label) is a parsed shortcut, not raw bytes")
    check(button?.canSend == true, "\(label) can send")
}

// The ids double as SwiftUI identity (`PanelButton.id`), so a duplicate would
// drop a row silently, exactly as a duplicated agent-button id does.
check(Set(controls.map(\.id)).count == controls.count,
      "the Ctrl page has no duplicate ids")
check(Set(controls.map(\.label)).count == controls.count,
      "and no two buttons are labelled the same")

// MARK: - A broken button declines the tap rather than sending

// The rule the header states: a problem button stays long-pressable to be
// edited, but a tap on it must send nothing. `canSend` is the whole guard, so
// each of its three inputs is exercised — a button with a parse failure, one
// with no payload, and each of the two good shapes.
let broken = PanelButton(id: "x", label: "X", detail: "", parsed: nil, raw: nil,
                         problem: "no longer parses")
check(!broken.canSend, "a button with a problem does not send on a tap")
let empty = PanelButton(id: "x", label: "X", detail: "", parsed: nil, raw: nil, problem: nil)
check(!empty.canSend, "a button with no payload does not send")
let parsedOnly = PanelButton(id: "x", label: "X", detail: "",
                             parsed: try? ShortcutGrammar.parse("C-c"), raw: nil, problem: nil)
check(parsedOnly.canSend, "a parsed button sends")
let rawOnly = PanelButton(id: "x", label: "X", detail: "", parsed: nil, raw: [0x02, 0x6E],
                          problem: nil)
check(rawOnly.canSend, "a raw-bytes button sends")

// MARK: - The multiplexer page offers exactly the commands its mux binds

// `muxButtons` filters `MuxCommand.allCases` through `isAvailable(on:)`, so the
// failure it guards is a button for a binding the host does not have — which
// types a stray control character into whatever is running in the pane, with no
// error. Each mux's expected set is written out independently of the code under
// test, from `MuxCommand.isAvailable`, so a change to either side fails here.

func muxIDs(_ mux: String?) -> [String] {
    AgentPanelPages.muxButtons(mux: mux, prefix: .controlB).map(\.id)
}

// order of allCases: nextPane, previousPane, nextTab, previousTab,
// nextSession, previousSession, zoomPane, newWindow, detach,
// workspaceNavigator, gotoPrompt
check(muxIDs("tmux") == ["nextPane", "previousPane", "nextTab", "previousTab",
                         "nextSession", "previousSession", "zoomPane",
                         "newWindow", "detach"],
      "tmux gets its pane, tab, session, zoom, new-window and detach commands, and nothing else")
check(muxIDs("zellij") == ["nextTab", "previousTab", "zoomPane"],
      "zellij gets only the tab and zoom commands it can express as line actions")
check(muxIDs("herdr") == ["nextPane", "previousPane", "nextTab", "previousTab",
                          "zoomPane", "workspaceNavigator", "gotoPrompt"],
      "herdr gets its panes, tabs, zoom and the two navigator chords")
check(muxIDs("wezterm") == [], "an unknown multiplexer gets no mux buttons at all")
check(muxIDs(nil) == [], "and a plain shell gets no mux page")

// The bytes themselves, hand-computed from the mux's published defaults. A
// wrong letter here is a *different binding* in herdr, not a no-op.
func muxBytes(_ id: String, mux: String, _ prefix: MuxSettings.Prefix) -> [UInt8]? {
    AgentPanelPages.muxButtons(mux: mux, prefix: prefix).first { $0.id == id }?.raw
}

checkBytes(muxBytes("nextPane", mux: "tmux", .controlB), [0x02, 0x6F], "tmux next pane is Ctrl-b o")
checkBytes(muxBytes("previousPane", mux: "tmux", .controlB), [0x02, 0x3B], "tmux previous pane is Ctrl-b ;")
checkBytes(muxBytes("nextTab", mux: "tmux", .controlB), [0x02, 0x6E], "tmux next window is Ctrl-b n")
checkBytes(muxBytes("previousTab", mux: "tmux", .controlB), [0x02, 0x70], "tmux previous window is Ctrl-b p")
checkBytes(muxBytes("nextSession", mux: "tmux", .controlB), [0x02, 0x29], "tmux next session is Ctrl-b )")
checkBytes(muxBytes("previousSession", mux: "tmux", .controlB), [0x02, 0x28], "tmux previous session is Ctrl-b (")
checkBytes(muxBytes("zoomPane", mux: "tmux", .controlB), [0x02, 0x7A], "tmux zoom pane is Ctrl-b z")

checkBytes(muxBytes("nextPane", mux: "herdr", .controlB), [0x02, 0x6A], "herdr next pane is prefix j")
checkBytes(muxBytes("previousPane", mux: "herdr", .controlB), [0x02, 0x6B], "herdr previous pane is prefix k")
checkBytes(muxBytes("nextTab", mux: "herdr", .controlB), [0x02, 0x6E], "herdr next tab is prefix n")
checkBytes(muxBytes("previousTab", mux: "herdr", .controlB), [0x02, 0x70], "herdr previous tab is prefix p")
checkBytes(muxBytes("zoomPane", mux: "herdr", .controlB), [0x02, 0x7A], "herdr zoom is prefix z")
checkBytes(muxBytes("workspaceNavigator", mux: "herdr", .controlB), [0x02, 0x77], "herdr navigator is prefix w")
checkBytes(muxBytes("gotoPrompt", mux: "herdr", .controlB), [0x02, 0x67], "herdr goto is prefix g")

checkBytes(muxBytes("nextTab", mux: "zellij", .controlB), Array("zellij action go-to-next-tab\n".utf8),
           "zellij next tab is its own line command, not a chord")
checkBytes(muxBytes("previousTab", mux: "zellij", .controlB), Array("zellij action go-to-previous-tab\n".utf8),
           "zellij previous tab is the previous-tab action")
checkBytes(muxBytes("zoomPane", mux: "zellij", .controlB), Array("zellij action toggle-fullscreen\n".utf8),
           "zellij zoom is toggle-fullscreen")

// The prefix setting must reach the wire: every tmux chord changes its head
// byte and nothing else when the user has rebound the prefix to Ctrl-a or
// Ctrl-Space. Both fail silently otherwise — a Ctrl-b into a Ctrl-a tmux does
// nothing at all.
for (id, tail) in [("nextPane", 0x6F), ("previousPane", 0x3B), ("nextTab", 0x6E),
                   ("previousTab", 0x70), ("zoomPane", 0x7A)] {
    checkBytes(muxBytes(id, mux: "tmux", .controlA), [0x01, UInt8(tail)],
               "with a Ctrl-a prefix, tmux \(id) leads with 0x01")
    checkBytes(muxBytes(id, mux: "tmux", .controlSpace), [0x00, UInt8(tail)],
               "with a Ctrl-Space prefix, tmux \(id) leads with 0x00")
}

// Every mux button is raw bytes with no shortcut text behind it — the prefix is
// a setting, not grammar — and carries no problem.
for button in AgentPanelPages.muxButtons(mux: "tmux", prefix: .controlB) {
    check(button.raw != nil && button.parsed == nil,
          "mux \(button.id) is sent as raw bytes, not through the grammar")
    check(button.problem == nil, "mux \(button.id) carries no problem")
    check(button.canSend, "mux \(button.id) can send")
}

// MARK: - Source detection: dedup and stable order

// The detection feeds the panel's segmented tabs, so an unstable order is a tab
// that moves every time the panel opens — reachable by holding Ctrl twice. The
// order must come from `AgentKind.allCases`, not from the order events arrived.
check(AgentPanelPages.detect(fromSources: []) == [],
      "no events detect no agents")
check(AgentPanelPages.detect(fromSources: ["claude-code"]) == [.claudeCode],
      "a claude-code event detects the Claude panel")
check(AgentPanelPages.detect(fromSources: ["codex", "claude"]) == [.claudeCode, .codex],
      "order comes from allCases, not from event arrival order")
check(AgentPanelPages.detect(fromSources: ["claude", "codex"]) == [.claudeCode, .codex],
      "and is the same whichever order the sources arrive in")
check(AgentPanelPages.detect(fromSources: ["cursor", "codex", "claude-code"]) ==
        [.claudeCode, .codex, .cursor],
      "all three agents come back in allCases order")

// Deduplication is the subtle one: the same agent can arrive as dozens of
// events, and under two spellings ("claude-code" from the hook, "claude" from
// an older one). Without the filter running once per kind, the tab row would
// show the same agent several times over.
check(AgentPanelPages.detect(fromSources: ["claude-code", "claude-code", "claude-code"]) ==
        [.claudeCode],
      "repeated events from one agent yield one tab")
check(AgentPanelPages.detect(fromSources: ["claude-code", "claude"]) == [.claudeCode],
      "the two spellings of the same agent do not both appear")
check(AgentPanelPages.detect(fromSources: ["CLAUDE-CODE", "Codex"]) == [.claudeCode, .codex],
      "detection is case-insensitive, as the model's own detection is")

// An agent with no panel is absent, but Cursor — a *documented, empty* panel —
// must still appear, because the emptiness is the honest answer and a missing
// tab would read as the app not noticing the agent at all.
check(AgentPanelPages.detect(fromSources: ["kimi-code", "antigravity"]) == [],
      "agents with no panel are not shown at all")
check(AgentPanelPages.detect(fromSources: ["cursor"]) == [.cursor],
      "Cursor appears even though its panel is empty")

// MARK: - Verdict

if failures > 0 {
    print("\nAGENTPANEL_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nAGENTPANEL_PASS  (\(checks) checks)")