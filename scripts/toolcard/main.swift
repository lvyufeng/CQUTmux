import Foundation

// The tool card's shape classifier, checked without a simulator.
//
// Every rule fails silently: an unrecognised shape still renders — as raw JSON
// — so a card that classifies an `Edit` wrongly merely looks like the wrong
// thing, and nothing reports an error. The rules are therefore driven with real
// tool payloads rather than looked at on a screen.
//
// `ToolShape.swift` is Foundation-only, so it runs here directly.

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

func shape(_ name: String, _ input: String) -> ToolShape.Shape {
    ToolShape.shape(name: name, input: input)
}

// MARK: - Diffs

// A simple edit: one line changed. The removed and added lines are the middle;
// the unchanged lines above and below are context.
let edit = """
{"file_path":"Sources/App.swift","old_string":"let a = 1\\nlet b = 2\\nlet c = 3","new_string":"let a = 1\\nlet b = 99\\nlet c = 3"}
"""
let editShape = shape("Edit", edit)
check(editShape == .diff(ToolShape.MiniDiff(path: "Sources/App.swift", lines: [
    .init(kind: .context, text: "let a = 1"),
    .init(kind: .removed, text: "let b = 2"),
    .init(kind: .added, text: "let b = 99"),
    .init(kind: .context, text: "let c = 3"),
], truncated: false)), "an edit becomes a mini diff with context and one change\n  got: \(editShape)")

// The counts the card shows in its collapsed row.
if case .diff(let diff) = editShape {
    check(diff.added == 1 && diff.removed == 1, "the mini diff counts one added and one removed line")
} else {
    check(false, "the edit did not produce a diff")
}

// A trailing newline is what editors write and no one means as a line. Keeping
// it makes every diff show a spurious blank addition.
check(ToolShape.splitLines("a\nb\n") == ["a", "b"], "a single trailing newline is dropped")
check(ToolShape.splitLines("a\n\nb") == ["a", "", "b"], "an interior blank line is kept")
check(ToolShape.splitLines("") == [], "an empty string has no lines")

// A line that is unchanged must not appear as both context and a change — the
// bug a suffix scan that does not stop where the prefix ended produces.
let repeated = """
{"file_path":"f","old_string":"same\\nold\\nsame","new_string":"same\\nnew\\nsame"}
"""
if case .diff(let diff) = shape("Edit", repeated) {
    let sameCount = diff.lines.filter { $0.text == "same" }.count
    check(sameCount == 2, "a repeated unchanged line appears once as context each: \(sameCount)")
    check(diff.lines == [
        .init(kind: .context, text: "same"),
        .init(kind: .removed, text: "old"),
        .init(kind: .added, text: "new"),
        .init(kind: .context, text: "same"),
    ], "the trimmed diff puts prefix, changes, then suffix in order")
} else {
    check(false, "a repeated-line edit did not produce a diff")
}

// A pure insertion: nothing removed, everything else context.
let insertion = """
{"file_path":"f","old_string":"a\\nc","new_string":"a\\nb\\nc"}
"""
if case .diff(let diff) = shape("Edit", insertion) {
    check(diff.removed == 0 && diff.added == 1, "a pure insertion removes nothing")
} else {
    check(false, "an insertion did not produce a diff")
}

// The prefix and the suffix must not overlap. When the added text repeats the
// text that is already there, a suffix scan that is not bounded by where the
// prefix stopped walks back *past* it, and the two ranges cross — which is an
// invalid range at best and a crash at worst.
let repeatedAppend = """
{"file_path":"f","old_string":"x","new_string":"x\\nx"}
"""
let appendShape = shape("Edit", repeatedAppend)
check(appendShape == .diff(ToolShape.MiniDiff(path: "f", lines: [
    .init(kind: .context, text: "x"),
    .init(kind: .added, text: "x"),
], truncated: false)), "a repeated append does not make the prefix and suffix overlap\n  got: \(appendShape)")

// Write is all additions: there is no old side.
let write = """
{"file_path":"New.swift","content":"import Foundation\\nlet x = 1\\n"}
"""
if case .diff(let diff) = shape("Write", write) {
    check(diff.added == 2 && diff.removed == 0, "a Write is all additions (got \(diff.added)/\(diff.removed))")
    check(diff.path == "New.swift", "the Write's path is carried")
} else {
    check(false, "a Write did not produce a diff")
}

// MultiEdit: several edits to one file, shown as one diff of what happened.
let multi = """
{"file_path":"f","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"}]}
"""
if case .diff(let diff) = shape("MultiEdit", multi) {
    check(diff.added == 2 && diff.removed == 2, "MultiEdit folds its edits into one diff (got \(diff.added)/\(diff.removed))")
} else {
    check(false, "a MultiEdit did not produce a diff")
}

// Case does not matter — agents write the tool name however they like.
check(shape("edit", edit) == editShape, "the tool name is matched case-insensitively")

// An edit with no actual change is not a card. A diff with nothing in it reads
// as a change that did not happen.
let noChange = """
{"file_path":"f","old_string":"same","new_string":"same"}
"""
check(shape("Edit", noChange) == .plain, "an edit with no change is not a diff")

// The clamp: a huge diff is truncated, and it *says* so. A clamp that does not
// report itself reads as the whole change.
let big = (0..<500).map { "line \($0)" }.joined(separator: "\\n")
let bigEdit = "{\"file_path\":\"f\",\"content\":\"\(big)\"}"
if case .diff(let diff) = shape("Write", bigEdit) {
    check(diff.truncated, "a 500-line Write is marked truncated")
    check(diff.lines.count == ToolShape.maxDiffLines + 1,
          "the truncated diff keeps maxDiffLines plus its marker (got \(diff.lines.count))")
    check(diff.lines.last?.text.contains("more lines") == true,
          "the truncation says how many lines are hidden: \(diff.lines.last?.text ?? "nil")")
} else {
    check(false, "a large Write did not produce a diff")
}

// MARK: - Tasks

let todos = """
{"todos":[{"content":"Read the file","status":"completed"},
          {"content":"Change the parser","status":"in_progress"},
          {"content":"Run the tests","status":"pending"}]}
"""
let taskShape = shape("TodoWrite", todos)
check(taskShape == .tasks([
    .init(content: "Read the file", status: .completed),
    .init(content: "Change the parser", status: .inProgress),
    .init(content: "Run the tests", status: .pending),
]), "a TodoWrite becomes the task list in order\n  got: \(taskShape)")

// The agents disagree on the spelling. All the documented ones map, and the
// separator is ignored.
check(ToolShape.status("in_progress") == .inProgress, "in_progress is in progress")
check(ToolShape.status("in-progress") == .unknown, "a hyphen spelling this build does not list is unknown, not guessed")
check(ToolShape.status("completed") == .completed, "completed is completed")
check(ToolShape.status("done") == .completed, "done is completed")
check(ToolShape.status("pending") == .pending, "pending is pending")

// An unrecognised status is unknown, *not* pending: a task the agent marked in
// a way this build does not know is not a task it has not started.
check(ToolShape.status("blocked") == .unknown, "an unknown status is unknown, not pending")
check(ToolShape.status(nil) == .unknown, "a missing status is unknown, not pending")

// An empty task list is not a card.
check(shape("TodoWrite", "{\"todos\":[]}") == .plain, "an empty task list is not a card")
check(shape("TodoWrite", "{}") == .plain, "a TodoWrite with no todos is not a card")

// MARK: - Plans

let plan = """
{"plan":"# Plan\\n\\n1. Look at the file\\n2. Change it"}
"""
if case .plan(let text) = shape("ExitPlanMode", plan) {
    check(text.hasPrefix("# Plan"), "a plan is kept as Markdown for the card to render")
} else {
    check(false, "ExitPlanMode did not produce a plan: \(shape("ExitPlanMode", plan))")
}

// An empty plan is not a card, and neither is whitespace pretending to be one.
check(shape("ExitPlanMode", "{\"plan\":\"   \"}") == .plain, "a whitespace-only plan is not a card")
check(shape("ExitPlanMode", "{}") == .plain, "a plan with no text is not a card")

// MARK: - The safe fallback

// Unknown tools, unparseable input and missing fields all stay plain. This
// feature's failure mode is a card that looks slightly wrong, so the fallback
// has to be the shape the app already had rather than a guess.
check(shape("Bash", "{\"command\":\"ls\"}") == .plain, "a Bash call stays a plain card")
check(shape("Edit", "not json at all") == .plain, "unparseable input stays plain")
check(shape("Edit", "\"just a string\"") == .plain, "an input that is not an object stays plain")
check(shape("Edit", "{\"file_path\":\"f\"}") == .plain, "an edit with no strings stays plain")

if failures > 0 {
    print("\nTOOLCARD_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nTOOLCARD_PASS  (\(checks) checks)")