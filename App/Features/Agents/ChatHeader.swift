import Foundation

/// What the Chat View's header says: which agent, which model, which session,
/// and what the diff and preview controls are offering.
///
/// The view itself is three `Text`s and two buttons. *What those say* is here,
/// because the three derivations are the kind that fail silently: a model that
/// is shown wrong still renders, a session id that is too long is not an error
/// but a header that has been squeezed to nothing, and a control summary that
/// counts the wrong thing reads as a working feature until someone taps it.
///
/// Foundation-only, so a check can drive the real derivation instead of a copy.
struct ChatHeader: Equatable {
    /// The agent the session belongs to, as the app names it — "Claude Code",
    /// not "claude-code".
    var agent: String
    /// The model of the newest turn that reported one, shortened for a header.
    var model: String?
    /// The session's short id, from the transcript's filename.
    var session: String?
    /// What the diff and preview controls would open, one phrase each. Assigned
    /// in a second step: the controls fetch their own data, and a header that
    /// claimed "3 changed files" before the fetch landed would be showing a
    /// number it had not read.
    private(set) var controlSummaries: [String] = []

    init(agent: String, model: String? = nil, session: String? = nil) {
        self.agent = agent
        self.model = model
        self.session = session
    }

    /// Fills in the controls once their data has arrived. Kept separate from
    /// `init` so the header can be drawn before the diff and preview calls
    /// finish — waiting for them would leave the header blank on every open.
    mutating func setControls(_ summaries: [String]) {
        controlSummaries = summaries.filter { !$0.isEmpty }
    }

    /// The one line under the title: agent, model, session, with the empty
    /// parts left out rather than leaving gaps or stray separators.
    var subtitle: String {
        ([agent, model, session].compactMap { $0 }).joined(separator: " · ")
    }

    /// The controls as one phrase, or nil when there is nothing to offer. A
    /// blunt "· diff · preview" tells the reader a button exists without saying
    /// whether there is anything behind it.
    var controlsSummary: String? {
        controlSummaries.isEmpty ? nil : controlSummaries.joined(separator: " · ")
    }

    // MARK: - Derivation

    /// The model of the newest message that reports one.
    ///
    /// Newest rather than first: a session can be switched between models, and
    /// the header should name the one doing the work now. `nil` when no message
    /// carries a model, which is every transcript from an agent that does not
    /// report it — showing the previous model there would be a lie about the
    /// current one.
    static func model(in messages: [AgentMessage]) -> String? {
        for message in messages.reversed() {
            if let model = message.model, !model.isEmpty {
                return short(model: model)
            }
        }
        return nil
    }

    /// Shortens an API model id for a header.
    ///
    /// `claude-opus-4-5-20250929` is 26 characters of which four carry meaning
    /// to a reader. The rule for which parts are which — a name word, then the
    /// version numbers, then a date — is applied only to ids that look like
    /// `claude-*`. Anything else is returned verbatim: guessing at a naming
    /// scheme this build has not seen is how a header comes to name a model
    /// that is not running.
    static func short(model: String) -> String {
        let lower = model.lowercased()
        guard lower.hasPrefix("claude-") else { return model }
        let parts = lower.dropFirst("claude-".count).split(separator: "-").map(String.init)
        // The name word and the version numbers are separated rather than taken
        // in order, because the scheme is both `opus-4-5` and `3-5-sonnet` and
        // reading positionally gets one of them wrong.
        let words = parts.filter { $0.first?.isLetter == true }
        // A trailing 8-digit run is a date. A short number is a version.
        let numbers = parts.filter { $0.first?.isNumber == true && $0.count < 8 }
        guard let name = words.first, !name.isEmpty else { return model }
        let title = name.prefix(1).uppercased() + name.dropFirst()
        return numbers.isEmpty ? title : "\(title) \(numbers.joined(separator: "."))"
    }

    /// What the header says the diff control offers, as a list of zero or one
    /// summary.
    ///
    /// A count of the changed files rather than the word "diff": the reader's
    /// question is whether there is anything to look at, and "Changes (0)" is a
    /// worse answer than the control simply not being there. A clean tree and a
    /// directory that is not a repository both produce nothing.
    static func controls(fileCount: Int?, isRepo: Bool) -> [String] {
        guard isRepo, let fileCount, fileCount > 0 else { return [] }
        return ["\(fileCount) changed file\(fileCount == 1 ? "" : "s")"]
    }

    /// A transcript filename's session id, shortened to something a header can
    /// hold.
    ///
    /// Claude Code names its log `<session-uuid>.jsonl`. The whole uuid is a
    /// header nobody can read and no layout can fit, so the first eight
    /// characters stand in — enough to tell two sessions apart at a glance,
    /// which is the only job the header has for it.
    static func session(fromFile file: String?) -> String? {
        guard let file, !file.isEmpty else { return nil }
        let base = (file as NSString).lastPathComponent
        guard base.hasSuffix(".jsonl") else { return base.isEmpty ? nil : base }
        let id = String(base.dropLast(".jsonl".count))
        guard !id.isEmpty else { return nil }
        return id.count > 8 ? String(id.prefix(8)) : id
    }
}