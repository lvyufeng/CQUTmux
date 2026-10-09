import Foundation

/// The Inbox as a board rather than a log.
///
/// Moshi's inbox is three columns — "Needs you", "Working", "Done" — with one
/// row per session, new events merging into the row that already exists, and an
/// archive underneath. Ours was a flat list of events, which is a different
/// thing wearing the same name: a session with twenty events produced twenty
/// rows, and nothing ever left.
///
/// The rules live here rather than in the view because every one of them fails
/// quietly. A row filed under the wrong column, or archived a minute early, is
/// not a crash — it is an inbox that is simply missing the thing you were
/// waiting for, which is the one failure a notification surface cannot have.
/// Being Foundation-only means `scripts/inbox-check.sh` can drive them with
/// constructed events instead of a host.
struct InboxBoard {
    // MARK: - Shape

    /// Which of the three columns a row sits in.
    ///
    /// Declared in the order Moshi shows them, and `Comparable` so that order
    /// cannot be re-decided by whoever sorts a list of columns later.
    enum Column: String, CaseIterable, Identifiable, Comparable {
        case needsYou
        case working
        case done

        var id: String { rawValue }

        var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .working: "Working"
            case .done: "Done"
            }
        }

        static func < (left: Column, right: Column) -> Bool {
            let order = Column.allCases
            return (order.firstIndex(of: left) ?? 0) < (order.firstIndex(of: right) ?? 0)
        }
    }

    /// One session's worth of events.
    struct Row: Identifiable {
        /// The session this row merges. Stable across polls, which is what
        /// makes merging possible at all.
        var id: String
        /// The row's own name: the project directory where we have one, the
        /// source otherwise.
        var title: String
        var subtitle: String
        var project: String?
        var column: Column
        /// Newest first.
        var events: [AgentEvent]
        /// The approval or question still waiting on an answer, if any.
        var pending: AgentEvent?
        /// Newest event of any kind, for sorting and for the age rules.
        var latest: Date?
        var isArchived: Bool
    }

    // MARK: - Rules

    /// A completed turn stays on the board this long before it files itself
    /// away. Moshi's number.
    static let completedLifetime: TimeInterval = 10 * 60

    /// The backstop, for rows that never complete: an approval the host timed
    /// out, or a session that went quiet mid-turn. Applies to every column, so
    /// nothing can stay on the board forever.
    static let maxLifetime: TimeInterval = 6 * 60 * 60

    /// Our own bookkeeping notices — the gateway emits one when an approval is
    /// resolved. They are real events and are kept, but they must not decide
    /// which column a row is in: an answered approval means the agent has
    /// started doing the thing, not that it finished, and treating the notice
    /// as completion would move every row to Done at the moment it was
    /// answered.
    static let ownSource = "app"

    // MARK: - Output

    private(set) var rows: [Row] = []

    var active: [Row] { rows.filter { !$0.isArchived } }
    var archived: [Row] { rows.filter { $0.isArchived } }

    func rows(in column: Column) -> [Row] {
        active.filter { $0.column == column }
    }

    /// Rows of one column, grouped by project for multi-repo work.
    ///
    /// Groups with something waiting bubble up; ties break by recency, which is
    /// the same rule the rows themselves use. Returns a single unnamed group
    /// when the column has no project worth separating — one header over one
    /// group is noise, and a header that appears and disappears as unrelated
    /// sessions come and go is worse.
    func groups(in column: Column) -> [(project: String, rows: [Row])] {
        let rows = rows(in: column)
        let named = rows.filter { $0.project != nil }
        guard named.count != rows.count || Set(named.compactMap(\.project)).count > 1 else {
            return [(project: "", rows: rows)]
        }

        var byProject: [String: [Row]] = [:]
        for row in rows {
            byProject[row.project ?? "", default: []].append(row)
        }
        return byProject
            .map { (project: $0.key, rows: $0.value) }
            .sorted { (left: (project: String, rows: [Row]), right: (project: String, rows: [Row])) in
                let leftWaiting = left.rows.contains { $0.pending != nil }
                let rightWaiting = right.rows.contains { $0.pending != nil }
                if leftWaiting != rightWaiting { return leftWaiting }
                // Unnamed last: it is the leftovers, not a project.
                if (left.project.isEmpty) != (right.project.isEmpty) { return !left.project.isEmpty }
                return Self.newest(left.rows) > Self.newest(right.rows)
            }
    }

    private static func newest(_ rows: [Row]) -> Date {
        rows.compactMap(\.latest).max() ?? .distantPast
    }

    // MARK: - Folding in answers that arrived elsewhere

    /// Applies our own resolution notices to the events they resolve.
    ///
    /// An approval can be answered somewhere this device cannot see: on the
    /// watch, on another phone, or by the host timing it out. The poll asks for
    /// `id > lastId`, so an event this device already holds is never re-sent
    /// with its new decision on it — the only thing that arrives is the
    /// gateway's notice. Without folding it back, the approval sits in "Needs
    /// you" forever and the user answers it again.
    ///
    /// The notice's own values are what win: they are the host's record of the
    /// decision, which beats anything held locally.
    ///
    /// The notice is then *removed*. Our bookkeeping is not something that
    /// happened in the user's session, and left in it would take over the row's
    /// summary — "CQUTmux · approval allow" as the newest line of every row the
    /// user had just answered. It has done its job once the decision is folded
    /// back, and a row is the agent's work, not ours.
    private static func folding(_ events: [AgentEvent]) -> [AgentEvent] {
        var notices: [Int: AgentEvent] = [:]
        for event in events where isOwnResolution(event) {
            if let target = event.resolvesEventID { notices[target] = event }
        }

        return events.compactMap { event in
            if isOwnResolution(event) { return nil }
            guard let notice = notices[event.id] else { return event }
            var updated = event
            if let decision = notice.data?.decision, event.decision == nil {
                updated.decision = decision
            }
            if let answer = notice.data?.answer, event.answer == nil {
                updated.answer = answer
            }
            // The notice is later activity than the request it answers, so the
            // row's 10-minute and 6-hour clocks run from the answer rather than
            // from the moment the question was asked.
            updated.at = notice.at
            return updated
        }
    }

    /// A notice that exists only to say an approval was answered.
    ///
    /// Requires the `for` as well as the source: the source alone would fold
    /// away anything we might emit later that a user is meant to read.
    private static func isOwnResolution(_ event: AgentEvent) -> Bool {
        event.source == ownSource && event.resolvesEventID != nil
    }

    // MARK: - Building

    /// Folds a page of events into rows.
    ///
    /// `manuallyArchived` is the rows the user swiped away. It is passed in
    /// rather than kept here so the decision stays a pure function of the
    /// input, which is what lets the checks drive it.
    init(events: [AgentEvent], now: Date = Date(), manuallyArchived: Set<String> = []) {
        let events = Self.folding(events)
        // The gateway's resolution notice names the event it resolves and no
        // session, and its own comment says clients should tolerate that. Left
        // alone it is a row of its own, so answering an approval would show the
        // question in "Needs you" and a brand-new "approval allow" row in
        // Done — two rows for one conversation, which is exactly the merging
        // this board exists to do.
        var sessionOf: [Int: String] = [:]
        for event in events where sessionOf[event.id] == nil {
            sessionOf[event.id] = event.sessionKey
        }
        func key(_ event: AgentEvent) -> String {
            if event.source == Self.ownSource,
               let target = event.resolvesEventID,
               let session = sessionOf[target] {
                return session
            }
            return event.sessionKey
        }

        var bySession: [String: [AgentEvent]] = [:]
        for event in events {
            bySession[key(event), default: []].append(event)
        }

        rows = bySession.map { session, events in
            Self.row(session: session, events: events, now: now,
                     manuallyArchived: manuallyArchived)
        }
        .sorted { Self.order($0) > Self.order($1) }
    }

    /// Newest activity first, and rows with no parseable time last rather than
    /// first: a broken timestamp is a broken row, and letting it lead the board
    /// would put the one row nobody can explain at the top. Hence the distant
    /// past rather than the distant future — the sort is descending, so the
    /// sentinel has to be the smallest thing there is.
    private static func order(_ row: Row) -> Date {
        row.latest ?? .distantPast
    }

    private static func row(
        session: String,
        events: [AgentEvent],
        now: Date,
        manuallyArchived: Set<String>
    ) -> Row {
        let byRecency = events.sorted { left, right in
            switch (left.date, right.date) {
            case let (left?, right?) where left != right: left < right
            // Same second, or no timestamp: the gateway's ids are monotonic,
            // so they order what the clock cannot.
            default: left.id < right.id
            }
        }
        let newest = byRecency.last
        // Our own notices are excluded from the column decision; see
        // `ownSource`. A session whose only events are ours still needs a
        // column, so the fallback is the whole list rather than nothing.
        let agentEvents = byRecency.filter { $0.source != ownSource }
        let deciding = agentEvents.last ?? newest

        let pending = byRecency.last { $0.isPending }

        let column: Column
        if pending != nil {
            column = .needsYou
        } else if deciding?.kind == .approval {
            // An answered approval is work in progress, not work finished.
            column = .working
        } else {
            column = .done
        }

        // Age is measured from the newest event of any kind: a resolution is
        // activity, and a row that was answered ten minutes ago is not an hour
        // old.
        let latest = newest?.date
        let age = latest.map { now.timeIntervalSince($0) } ?? 0
        // A completed turn clears out quickly; everything else has the long
        // backstop. Neither applies to a row still waiting on an answer — the
        // spec keeps that Active until it is answered or the host times it out,
        // and the host timing out is what the six hours stands in for.
        let expired: Bool
        switch column {
        case .needsYou: expired = age > Self.maxLifetime
        case .done: expired = age > Self.completedLifetime
        case .working: expired = age > Self.maxLifetime
        }

        let project = byRecency.last { $0.projectName != nil }?.projectName
        let source = deciding?.sourceLabel ?? "Host"

        return Row(
            id: session,
            title: project ?? source,
            subtitle: project == nil ? (newest?.sourceLabel ?? "") : source,
            project: project,
            column: column,
            events: byRecency.reversed(),
            pending: pending,
            latest: latest,
            isArchived: expired || manuallyArchived.contains(session)
        )
    }
}