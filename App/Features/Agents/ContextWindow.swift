import Foundation

/// How full an agent's context window is, from the newest turn that reported it.
///
/// The agent's own transcript log carries a `usage` object on every assistant
/// turn, and the one number worth putting on a row is *how much of the window
/// the last request occupied*: a coding agent loses coherence as it fills and
/// then compacts, and the phone is exactly where you notice it a turn too late.
///
/// Two things make this easy to get wrong, and both are why the arithmetic
/// lives here as a pure function rather than inline in a view:
///
/// - **It is not the sum of all turns.** Input tokens are re-sent every turn.
///   Adding them up would count the same context window once per message and
///   show a healthy session as permanently full. The window is the *last*
///   turn's `input_tokens + cache_read + cache_creation`, plus its
///   `output_tokens` — that last one is what the window holds *after* the turn,
///   which is the number that decides whether the next one fits.
/// - **The denominator is a guess.** The log does not state the limit. A wrong
///   limit is not a crash; it is a ring that never fills or always reads full,
///   which is why the limit is configurable and why the model refuses to draw a
///   percentage it cannot stand behind.
enum ContextWindow {
    /// What a turn's usage says about the window, before a limit is applied.
    struct Usage: Equatable {
        /// The distinct tokens occupying the window for this turn. Never a sum
        /// across turns — see the type's note.
        var tokens: Int
        /// The window size this was measured against.
        var limit: Int

        /// 0…1, clamped. A measurement above the limit reads as full rather
        /// than above full: a ring of 110% is a rendering bug, and "the window
        /// is full" is the true statement either way.
        var fraction: Double {
            guard limit > 0 else { return 0 }
            return min(1, max(0, Double(tokens) / Double(limit)))
        }

        /// Below this, the ring is warning-coloured. Moshi's band, and the same
        /// one the watch complication uses so the two do not disagree.
        static let warningFraction = 0.85

        var isWarning: Bool { fraction >= Self.warningFraction }

        /// What is left, in tokens. Can be zero, which is the honest answer
        /// when the last turn already exceeded the window.
        var remaining: Int { max(0, limit - tokens) }
    }

    /// Reads the newest usage block out of a transcript's messages.
    ///
    /// Newest first, and the *last* message that carries a usage wins — not the
    /// largest, and not the sum. A turn with no usage (a tool result, a user
    /// message) is skipped; only assistant turns report it.
    ///
    /// `usage` is `[String: Int]` rather than the four named fields because the
    /// log's key set drifts between agent releases, and a decode that insists
    /// on a key the agent stopped sending would throw away the whole reading —
    /// the same reason `AgentEvent`'s fields are optional.
    static func usage(from messages: [AgentMessage], limit: Int) -> Usage? {
        for message in messages.reversed() {
            guard let usage = message.usage else { continue }
            let tokens = tokens(from: usage)
            // A turn that reported only zeros is not a measurement — an agent
            // mid-compaction, or a log written by a version that stopped
            // filling the field. Reporting 0% full off it would be worse than
            // reporting nothing.
            guard tokens > 0 else { continue }
            return Usage(tokens: tokens, limit: limit)
        }
        return nil
    }

    /// The distinct tokens one turn's usage occupied.
    ///
    /// `input_tokens` is what was not cached; the two cache figures are the
    /// rest of what was sent; `output_tokens` is what the turn added. Cached
    /// and uncached input are disjoint in the protocol, so this is a sum of
    /// distinct parts rather than a double count.
    static func tokens(from usage: [String: Int]) -> Int {
        let input = usage["input_tokens"] ?? 0
        let cacheRead = usage["cache_read_input_tokens"] ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] ?? 0
        let output = usage["output_tokens"] ?? 0
        return input + cacheRead + cacheCreation + output
    }

    /// The window size assumed for an agent whose log does not state one.
    ///
    /// Configurable because the assumption is the one part of this that can be
    /// plainly wrong: the limit belongs to the model, the log does not record
    /// it, and a newer model with a different window would otherwise draw a
    /// ring against the wrong denominator with no way to correct it. The
    /// default is deliberately the commonly-cited figure rather than a
    /// measured one, and the settings screen says so.
    static let defaultLimit = 200_000
}