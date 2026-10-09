import Foundation

/// Parsing for the timestamps on the wire.
///
/// Not `ISO8601DateFormatter().date(from:)`, which is the obvious thing and is
/// wrong here. The gateway writes `new Date().toISOString()`, which always
/// carries milliseconds (`2026-10-09T04:15:30.123Z`), and a default-configured
/// `ISO8601DateFormatter` accepts only whole seconds — it returns `nil` for
/// every one of them. Nothing reports the failure: an optional date that is
/// quietly always nil renders as a blank timestamp, which looks like a layout
/// problem rather than a parsing one. That is how every relative time in the
/// app came to be missing its value, on every row, for as long as the code has
/// existed.
///
/// Both forms are accepted because agents are not the only producer: a human
/// editing an event by hand, or a different agent's hook, may write either.
enum ISODate {
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses a timestamp, or nil if it is not one. Never throws.
    static func parse(_ text: String) -> Date? {
        withFractionalSeconds.date(from: text) ?? plain.date(from: text)
    }

    /// Writes the same shape the gateway writes, milliseconds included.
    ///
    /// Here rather than at each call site so that a timestamp this app
    /// fabricates — a sample event for the Live Activity test — is one the
    /// parser above provably reads back. A locally built event with a `Date`
    /// description would parse to nil and show a blank time, which is the exact
    /// failure `parse` exists to have fixed.
    static func string(from date: Date) -> String {
        withFractionalSeconds.string(from: date)
    }
}