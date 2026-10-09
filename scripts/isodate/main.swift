import Foundation

// The shapes on the wire, and whether they parse.
//
// The case that matters is the first one: it is what `new Date().toISOString()`
// produces, which is what the gateway writes for every event and every
// transcript message. It did not parse.

var failures = 0
var checks = 0

func check(_ parsed: Date?, _ label: String) {
    checks += 1
    if parsed != nil {
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)")
    }
}

// MARK: - What the producers actually write

check(ISODate.parse("2026-10-09T04:15:30.123Z"),
      "a JavaScript toISOString timestamp parses (the one that did not)")

check(ISODate.parse("2026-10-09T04:15:30Z"),
      "a whole-second timestamp parses")

check(ISODate.parse("2026-10-09T04:15:30.000Z"),
      "a timestamp whose milliseconds are zero parses")

check(ISODate.parse("2026-10-09T04:15:30+00:00"),
      "an offset form parses")

check(ISODate.parse("2026-10-09T12:15:30.5+08:00"),
      "an offset with a fractional second parses")

// MARK: - The value, not just non-nil

// The failure mode this file exists for was a *nil*, but a parser that returned
// the wrong instant would be worse: it would render a plausible-looking time.
let exact = ISODate.parse("2026-10-09T04:15:30.123Z")
var components = DateComponents()
components.year = 2026
components.month = 10
components.day = 9
components.hour = 4
components.minute = 15
components.second = 30
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "UTC")!
let expected = calendar.date(from: components)!
checks += 1
if let exact, abs(exact.timeIntervalSince(expected) - 0.123) < 0.001 {
    print("PASS  the parsed instant is the one written, milliseconds included")
} else {
    failures += 1
    print("FAIL  the parsed instant is wrong: \(String(describing: exact)) vs \(expected)")
}

// MARK: - Refusing what is not a timestamp

// Silently accepting junk would turn a malformed event into an event dated
// 1970 or "now"; nil is the honest answer and the view already handles it.
checks += 1
if ISODate.parse("not a date") == nil {
    print("PASS  a non-timestamp yields nil rather than a guess")
} else {
    failures += 1
    print("FAIL  a non-timestamp parsed to something")
}

checks += 1
if ISODate.parse("") == nil {
    print("PASS  an empty string yields nil")
} else {
    failures += 1
    print("FAIL  an empty string parsed to something")
}

// A bare date is not a timestamp on this wire. Accepting it would mean a
// producer that dropped the time could go unnoticed.
checks += 1
if ISODate.parse("2026-10-09") == nil {
    print("PASS  a date with no time yields nil")
} else {
    failures += 1
    print("FAIL  a bare date parsed, which would hide a writer dropping the time")
}

if failures > 0 {
    print("\nISODATE_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nISODATE_PASS  (\(checks) checks)")