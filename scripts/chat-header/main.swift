import Foundation

// The Chat View header's derivations, checked without a simulator.
//
// Three of them fail silently: a model shown wrongly still renders, a session
// id too long is not an error but a header squeezed to nothing, and a control
// summary that counts the wrong thing reads as working until someone taps it.
//
// `ChatHeader.swift` is Foundation-only, so it runs here directly.

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

func message(_ model: String?, role: AgentMessage.Role = .assistant) -> AgentMessage {
    AgentMessage(id: UUID().uuidString, role: role, at: nil, blocks: [], model: model, usage: nil)
}

// MARK: - The model

// The real ids the app sees, and what a header can hold.
check(ChatHeader.short(model: "claude-opus-4-5-20250929") == "Opus 4.5",
      "a dated Opus id shortens to Opus 4.5 (got \(ChatHeader.short(model: "claude-opus-4-5-20250929")))")
check(ChatHeader.short(model: "claude-sonnet-4-5-20250929") == "Sonnet 4.5",
      "a Sonnet id shortens to Sonnet 4.5")
check(ChatHeader.short(model: "claude-haiku-4-5") == "Haiku 4.5", "an id with no date shortens the same way")

// The version-first spelling. Reading the parts positionally gets this one
// wrong — it would come out as "Sonnet 3.5" only if the name is found by
// *content*, not by position.
check(ChatHeader.short(model: "claude-3-5-sonnet-20241022") == "Sonnet 3.5",
      "a version-first id still names the model (got \(ChatHeader.short(model: "claude-3-5-sonnet-20241022")))")

// A date is not a version. Its eight digits must not appear in the header, or
// every model name becomes a timestamp.
check(!ChatHeader.short(model: "claude-opus-4-5-20250929").contains("2025"),
      "the release date is not shown as part of the version")

// An id this build does not recognise is shown verbatim. Guessing at a naming
// scheme is how a header comes to name a model that is not running.
check(ChatHeader.short(model: "gpt-5-codex") == "gpt-5-codex", "a foreign model id is shown as-is")
check(ChatHeader.short(model: "claude") == "claude", "a bare `claude` is left alone, not blanked")

// The newest message's model wins, because a session can be switched between
// models and the header should name the one doing the work now.
check(ChatHeader.model(in: [message("claude-opus-4-5"), message("claude-haiku-4-5")]) == "Haiku 4.5",
      "the newest message's model is the one shown")

// A newer message that reports no model does not erase the last one: the model
// is still the one running, and blanking it on every user turn would make the
// header flicker.
check(ChatHeader.model(in: [message("claude-opus-4-5"), message(nil)]) == "Opus 4.5",
      "a later message with no model does not blank the header")
check(ChatHeader.model(in: [message(nil), message(nil)]) == nil,
      "no model anywhere leaves the header without one")
check(ChatHeader.model(in: []) == nil, "an empty transcript has no model")

// MARK: - The session

// `<uuid>.jsonl` is what Claude Code writes. The first eight characters are
// enough to tell two sessions apart, which is the only job this has.
check(ChatHeader.session(fromFile: "8f14e45f-ceea-467a-9d0a-2b1c3d4e5f60.jsonl") == "8f14e45f",
      "a uuid filename shortens to its first eight characters")
check(ChatHeader.session(fromFile: "short.jsonl") == "short", "a short id is kept whole")
check(ChatHeader.session(fromFile: "8f14e45f.jsonl") == "8f14e45f", "exactly eight characters are kept whole")
check(ChatHeader.session(fromFile: nil) == nil, "no file means no session id")
check(ChatHeader.session(fromFile: "") == nil, "an empty filename means no session id")
check(ChatHeader.session(fromFile: ".jsonl") == nil, "a filename that is only the extension has no id")

// A path, not just a name: the wire sends the filename, but a caller passing a
// path must not make the session id read `projects`.
check(ChatHeader.session(fromFile: "/home/u/.claude/projects/x/8f14e45f.jsonl") == "8f14e45f",
      "only the last path component is used")

// MARK: - The subtitle

let full = ChatHeader(agent: "Claude Code", model: "Opus 4.5", session: "8f14e45f")
check(full.subtitle == "Claude Code · Opus 4.5 · 8f14e45f",
      "the subtitle joins agent, model and session (got \(full.subtitle))")

// Missing parts leave no stray separator: a header reading "Claude Code · · "
// looks broken rather than sparse.
check(ChatHeader(agent: "Claude Code").subtitle == "Claude Code",
      "a header with no model or session has no trailing separator")
check(ChatHeader(agent: "Claude Code", session: "8f14e45f").subtitle == "Claude Code · 8f14e45f",
      "skipping the model leaves one separator, not two")
check(ChatHeader(agent: "Codex", model: "gpt-5-codex").subtitle == "Codex · gpt-5-codex",
      "a model with no session joins cleanly")

// MARK: - The controls derivation

// The count comes from the working tree, so the header derives a phrase from it
// rather than being handed one. A clean tree, a non-repository and a failed
// fetch all produce nothing — the control is not offered, rather than offered
// and empty.
check(ChatHeader.controls(fileCount: 3, isRepo: true) == ["3 changed files"],
      "three changed files read as a count")
check(ChatHeader.controls(fileCount: 1, isRepo: true) == ["1 changed file"],
      "one changed file is singular")
check(ChatHeader.controls(fileCount: 0, isRepo: true) == [],
      "a clean tree offers no changes control")
check(ChatHeader.controls(fileCount: nil, isRepo: true) == [],
      "a fetch that did not land offers no changes control")
check(ChatHeader.controls(fileCount: 5, isRepo: false) == [],
      "a directory that is not a repository offers no changes control")

// And it wires into the header the same way the other summaries do.
var withChanges = ChatHeader(agent: "Claude Code")
withChanges.setControls(ChatHeader.controls(fileCount: 2, isRepo: true))
check(withChanges.controlsSummary == "2 changed files",
      "the derived control reads through the header")

// MARK: - The controls

// The summaries come from the fetches, so the header draws before they land.
// Adding them must not disturb what is already there.
var header = ChatHeader(agent: "Claude Code", model: "Opus 4.5", session: "8f14e45f")
check(header.controlsSummary == nil, "no controls are claimed before their data has arrived")
header.setControls(["3 changed files", "Preview"])
check(header.controlsSummary == "3 changed files · Preview",
      "the controls read as one phrase (got \(header.controlsSummary ?? "nil"))")

// An empty summary is dropped rather than leaving a gap: a control with nothing
// behind it should not appear at all, and "· preview" reads as a missing value.
header.setControls(["", "Preview", ""])
check(header.controlsSummary == "Preview", "empty summaries are dropped, not joined as blanks")
header.setControls([])
check(header.controlsSummary == nil, "clearing the controls leaves nothing claimed")

if failures > 0 {
    print("\nCHAT_HEADER_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nCHAT_HEADER_PASS  (\(checks) checks)")