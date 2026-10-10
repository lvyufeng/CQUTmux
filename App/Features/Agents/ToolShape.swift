import Foundation

/// How a tool call should be drawn.
///
/// A tool card that expands to raw JSON is legible to the person who wrote the
/// agent, and not to anyone else: an `Edit` shows two escaped strings and makes
/// the reader diff them by eye, a `TodoWrite` shows a list of objects, and a
/// plan — which the agent wrote as Markdown on purpose — is shown with its `#`
/// characters intact. Each of those is a *shape* the card could recognise and
/// draw as itself.
///
/// The classification is here, apart from the view, for the same reason as
/// `ChatMarkdown`: every rule fails silently. A shape that is not recognised
/// still renders — as plain JSON — so nothing reports an error and the card
/// merely looks like the wrong thing. Foundation-only, so a check can drive the
/// real classifier instead of a copy.
enum ToolShape {
    // MARK: - Shapes

    /// One line of a mini diff.
    struct DiffLine: Equatable {
        enum Kind: Equatable { case context, added, removed }
        var kind: Kind
        var text: String
    }

    /// A condensed view of what an edit changed.
    struct MiniDiff: Equatable {
        /// The file's path, or nil when the call did not name one.
        var path: String?
        var lines: [DiffLine]
        /// Whether lines were elided from the middle. A clamp that does not say
        /// so reads as the whole change.
        var truncated: Bool

        var added: Int { lines.filter { $0.kind == .added }.count }
        var removed: Int { lines.filter { $0.kind == .removed }.count }
    }

    /// One item of the agent's task list.
    struct TaskItem: Equatable {
        enum Status: Equatable { case pending, inProgress, completed, unknown }
        var content: String
        var status: Status
    }

    /// What to draw.
    enum Shape: Equatable {
        case diff(MiniDiff)
        /// The agent's task list, in the order it wrote them.
        case tasks([TaskItem])
        /// A plan, kept as Markdown for the card to render expanded.
        case plan(String)
        /// Nothing special: the existing collapsed row with its summary.
        case plain
    }

    /// At most this many diff lines are drawn; the rest are elided. An `Edit`
    /// can replace a whole file, and a card that grows to a thousand lines is
    /// not a card.
    static let maxDiffLines = 60
    /// At most this many tasks. Past this the list is a document, not a card.
    static let maxTasks = 50

    // MARK: - Classification

    /// Which shape `name`'s call takes, from its JSON `input`.
    ///
    /// Unknown tools, unparseable JSON and missing fields all fall back to
    /// `.plain` — the card the app already had. That is deliberate: this
    /// feature's failure mode is a card that looks slightly wrong, so the
    /// fallback has to be the safe thing rather than a guess.
    static func shape(name: String, input: String) -> Shape {
        guard let object = jsonObject(input) else { return .plain }
        switch name.lowercased() {
        case "edit", "multiedit", "notebookedit":
            return editShape(name: name, object: object)
        case "write":
            return writeShape(object)
        case "todowrite", "todo_write", "task":
            return tasksShape(object)
        case "exitplanmode", "exit_plan_mode":
            return planShape(object)
        default:
            return .plain
        }
    }

    // MARK: - Edits

    private static func editShape(name: String, object: [String: Any]) -> Shape {
        let path = object["file_path"] as? String ?? object["path"] as? String
        // MultiEdit carries a list of edits rather than one pair; they are shown
        // as one diff because the card is about what happened to the file.
        if let edits = object["edits"] as? [[String: Any]] {
            var lines: [DiffLine] = []
            for edit in edits {
                let old = edit["old_string"] as? String ?? ""
                let new = edit["new_string"] as? String ?? ""
                lines += diffLines(old: old, new: new)
            }
            guard !lines.isEmpty else { return .plain }
            return .diff(clamp(MiniDiff(path: path, lines: lines, truncated: false)))
        }
        let old = object["old_string"] as? String ?? ""
        let new = object["new_string"] as? String ?? ""
        let lines = diffLines(old: old, new: new)
        guard !lines.isEmpty else { return .plain }
        return .diff(clamp(MiniDiff(path: path, lines: lines, truncated: false)))
    }

    private static func writeShape(_ object: [String: Any]) -> Shape {
        let path = object["file_path"] as? String ?? object["path"] as? String
        guard let content = object["content"] as? String, !content.isEmpty else { return .plain }
        // A whole new file is all additions — there is no old side to compare.
        let lines = splitLines(content).map { DiffLine(kind: .added, text: $0) }
        return .diff(clamp(MiniDiff(path: path, lines: lines, truncated: false)))
    }

    /// The lines that changed between two strings.
    ///
    /// Common leading and trailing lines become context and the differing middle
    /// becomes removals then additions. This is the classic trimmed diff rather
    /// than a full LCS: an `Edit` is usually a handful of contiguous lines, the
    /// middle is what the reader needs, and the untrimmed version shows a screen
    /// of unchanged context above and below every change.
    static func diffLines(old: String, new: String) -> [DiffLine] {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)

        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count,
              oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        // The suffix stops where the prefix ends, so a line is never counted
        // twice — the bug that makes an unchanged line appear both as context
        // and as a change.
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        var lines: [DiffLine] = []
        for index in 0..<prefix {
            lines.append(DiffLine(kind: .context, text: oldLines[index]))
        }
        for index in prefix..<(oldLines.count - suffix) {
            lines.append(DiffLine(kind: .removed, text: oldLines[index]))
        }
        for index in prefix..<(newLines.count - suffix) {
            lines.append(DiffLine(kind: .added, text: newLines[index]))
        }
        for index in (oldLines.count - suffix)..<oldLines.count {
            lines.append(DiffLine(kind: .context, text: oldLines[index]))
        }
        // Whitespace-only content is no change, not a blank card.
        let hasChange = lines.contains { $0.kind != .context }
        return hasChange ? lines : []
    }

    private static func clamp(_ diff: MiniDiff) -> MiniDiff {
        guard diff.lines.count > maxDiffLines else { return diff }
        var trimmed = Array(diff.lines.prefix(maxDiffLines))
        // Never end on a lone removal block: half a change reads as a deletion
        // that did not happen. The added lines that came with the last removal
        // stay in view.
        trimmed.append(DiffLine(kind: .context, text: "… \(diff.lines.count - maxDiffLines) more lines"))
        var result = diff
        result.lines = trimmed
        result.truncated = true
        return result
    }

    // MARK: - Tasks

    private static func tasksShape(_ object: [String: Any]) -> Shape {
        guard let raw = object["todos"] as? [[String: Any]] else { return .plain }
        let items: [TaskItem] = raw.compactMap { todo in
            guard let content = todo["content"] as? String ?? todo["text"] as? String,
                  !content.isEmpty
            else { return nil }
            return TaskItem(content: content, status: status(todo["status"] as? String))
        }
        guard !items.isEmpty else { return .plain }
        return .tasks(Array(items.prefix(maxTasks)))
    }

    /// The status the agent wrote.
    ///
    /// An unrecognised status is `.unknown`, not `.pending`: a task the agent
    /// marked in a way this build does not know is not a task it has not
    /// started, and drawing it as pending would misreport the agent's own
    /// record. Any spelling and separator is accepted — these are written by
    /// hand in prompts and the agents disagree.
    static func status(_ raw: String?) -> TaskItem.Status {
        switch raw?.lowercased().replacingOccurrences(of: "_", with: "") {
        case "completed", "complete", "done": return .completed
        case "inprogress", "active", "running": return .inProgress
        case "pending", "todo", "queued": return .pending
        default: return .unknown
        }
    }

    // MARK: - Plans

    private static func planShape(_ object: [String: Any]) -> Shape {
        // The field is `plan` in the tool's own payload; `content` is the
        // fallback, because some agents put the prose there.
        let text = object["plan"] as? String ?? object["content"] as? String
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .plain
        }
        return .plan(text)
    }

    // MARK: - Reading

    /// Parses a tool input, or nil. The input arrives as JSON text because the
    /// gateway carries it that way; a tool whose input is not an object (a bare
    /// string, say) is `.plain`.
    private static func jsonObject(_ input: String) -> [String: Any]? {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// Splits on newlines, dropping a single trailing newline.
    ///
    /// The trailing newline is what every editor writes and no one means as a
    /// line, so keeping it makes every diff show a spurious blank addition.
    /// Interior blank lines are the file's own layout and are kept.
    static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}