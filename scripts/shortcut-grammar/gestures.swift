import Foundation

// Exercises the gesture bindings without a simulator: the store is a plist
// plus the same parser the bar uses, so the interesting questions — what a
// gesture sends when unbound, when bound, and when the binding stops parsing —
// are all answerable here.
// Run with: scripts/shortcut-grammar/run.sh

// Top-level code is only allowed in `main.swift`, which the grammar checks
// already own, so this is its own entry point.
@main
enum GestureChecks {
    static var failures = 0

    static func main() {
        unboundDefaults()
        bindingReplacesDefault()
        clearingRestoresDefault()
        whitespaceIsAClear()
        unparsableFallsBack()
        bindingsSurviveRestart()

        print("\n\(failures == 0 ? "gesture check passed" : "gesture check FAILED (\(failures))")")
        exit(failures == 0 ? 0 : 1)
    }

    static func expect(_ got: [UInt8]?, _ want: [UInt8]?, _ note: String) {
        expect(got == want, note, got: String(describing: got), want: String(describing: want))
    }

    static func expect(_ got: String?, _ want: String?, _ note: String) {
        expect(got == want, note, got: String(describing: got), want: String(describing: want))
    }

    static func expect(_ got: Bool, _ want: Bool, _ note: String) {
        expect(got == want, note, got: "\(got)", want: "\(want)")
    }

    static func expect(_ got: Int, _ want: Int, _ note: String) {
        expect(got == want, note, got: "\(got)", want: "\(want)")
    }

    static func expect(_ pass: Bool, _ note: String, got: String, want: String) {
        if !pass { failures += 1 }
        print("\(pass ? "PASS" : "FAIL")  \(note)")
        if !pass { print("        got \(got) wanted \(want)") }
    }

    static func store() -> (GestureStore, UserDefaults) {
        // A scratch suite, so a test run cannot read or write real preferences.
        let suite = UserDefaults(suiteName: "cqutmux.gesture.tests.\(UUID().uuidString)")!
        return (GestureStore(defaults: suite), suite)
    }

    static func unboundDefaults() {
        print("— unbound defaults —")
        let (gestures, _) = store()
        expect(gestures.bytes(for: .doubleTap), [0x09], "double tap is Tab when unbound")
        expect(gestures.bytes(for: .swipeLeft), [0x02, 0x6E], "swipe left is next window when unbound")
        expect(gestures.bytes(for: .swipeRight), [0x02, 0x70], "swipe right is previous window when unbound")
        expect(gestures.bytes(for: .tripleTap), nil, "triple tap is unbound by default")
        expect(TerminalGesture.allCases.count, 4, "single tap is not offered: it is SwiftTerm's")
    }

    static func bindingReplacesDefault() {
        print("\n— a binding replaces the default —")
        let (gestures, _) = store()
        gestures.set("C-c", for: .doubleTap)
        expect(gestures.bytes(for: .doubleTap), [0x03], "double tap follows the binding")
        expect(gestures.bytes(for: .swipeLeft), [0x02, 0x6E], "binding one gesture leaves the others alone")
    }

    static func clearingRestoresDefault() {
        print("\n— clearing a binding restores the default —")
        let (gestures, _) = store()
        gestures.set("C-c", for: .doubleTap)
        gestures.set(nil, for: .doubleTap)
        expect(gestures.bytes(for: .doubleTap), [0x09], "clearing returns to Tab")
        expect(gestures.text(for: .doubleTap), nil, "the binding is gone, not blank")
    }

    static func whitespaceIsAClear() {
        print("\n— whitespace-only is a clear, not a binding —")
        let (gestures, _) = store()
        gestures.set("   ", for: .swipeLeft)
        expect(gestures.text(for: .swipeLeft), nil, "whitespace does not bind")
        expect(gestures.bytes(for: .swipeLeft), [0x02, 0x6E], "and the default still applies")
    }

    static func unparsableFallsBack() {
        print("\n— a binding that stops parsing falls back, and says why —")
        let (gestures, _) = store()
        gestures.set("nosuchkey", for: .doubleTap)
        expect(gestures.bytes(for: .doubleTap), [0x09], "an unparsable binding sends the default, not nothing")
        expect(gestures.problem(for: .doubleTap) != nil, true, "and the failure is reported")
        expect(gestures.text(for: .doubleTap), "nosuchkey", "the text is kept for the user to fix")
    }

    static func bindingsSurviveRestart() {
        print("\n— bindings survive a restart —")
        let (gestures, suite) = store()
        gestures.set("C-b, c", for: .tripleTap)
        // A second store over the same suite is what the next launch sees.
        let reopened = GestureStore(defaults: suite)
        expect(reopened.bytes(for: .tripleTap), [0x02, 0x63], "the binding was persisted")
        expect(reopened.bytes(for: .doubleTap), [0x09], "and the unbound default is unchanged")
    }
}