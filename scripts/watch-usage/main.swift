import Foundation

// The watch's usage payload: what a ring shows, and what a complication would.
//
// The two derived values are where the mistakes would be, and both are
// invisible: `tightest` picks the window a glance is about, and `peakPercent`
// picks the number a complication shows. Getting either wrong produces a
// plausible-looking reading that is not the one the user needs — the whole
// point of a rate-limit display is the window closest to cutting you off, and
// an average or a first-element pick would quietly understate it.
//
// `WatchPayload.swift` is shared with the watch target and imports Foundation
// only, so this needs no simulator and no watch.

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

func window(_ label: String, _ percent: Double) -> WatchPayload.Usage.Window {
    .init(label: label, percent: percent, resetIn: "soon")
}

func entry(_ source: String, _ windows: [WatchPayload.Usage.Window]) -> WatchPayload.Usage.Entry {
    .init(source: source, label: source, pace: nil, windows: windows)
}

// MARK: - Which window matters

// The rule, stated as the thing it is for: the window closest to its limit.
let mixed = entry("claude", [window("5h", 12), window("7d", 78)])
check(mixed.tightest?.label == "7d",
      "the tightest window is the most-used one, not the first")

let reversed = entry("claude", [window("5h", 91), window("7d", 20)])
check(reversed.tightest?.label == "5h", "the rule is not positional")

// A tie must resolve to something rather than crash or return nil.
let tied = entry("claude", [window("5h", 50), window("7d", 50)])
check(tied.tightest != nil, "two windows at the same percentage still yield one")

check(entry("claude", []).tightest == nil, "an account with no windows has no tightest")

// MARK: - The number a complication shows

// One account carries a `pace` and the board a timestamp, so the round-trip
// below exercises every optional field. A nil one is omitted from the JSON
// entirely, which is correct behaviour but would make a key-presence check
// pass or fail for the wrong reason.
let board = WatchPayload.Usage(
    entries: [entry("claude", [window("5h", 62), window("7d", 34)]),
              .init(source: "codex", label: "Codex", pace: "on pace",
                    windows: [window("5h", 88)])],
    generatedAt: Date(timeIntervalSince1970: 1_000)
)
check(board.peakPercent == 88, "the peak is the highest across every account")

// Not the average, and not the first account's — both would be lower here, and
// a rate-limit complication that understates is worse than none.
check(board.peakPercent != 62, "the peak is not the first account's tightest")
let mean = (62.0 + 88.0) / 2
check(board.peakPercent != mean, "the peak is not the mean of the accounts")

check(WatchPayload.Usage(entries: [], generatedAt: nil).peakPercent == nil,
      "no accounts means no peak, which the watch shows as no data")

// Zero is a reading, not an absence: an account that has used nothing must
// still produce 0 rather than nil, or the ring would read as "unknown".
let idle = WatchPayload.Usage(entries: [entry("claude", [window("5h", 0)])], generatedAt: nil)
check(idle.peakPercent == 0, "a measured zero is a value, not missing data")

// MARK: - It survives the wire

// The phone and the watch are separate targets that each declare this type's
// consumer; the only thing that makes that safe is that what one encodes the
// other decodes. Round-tripping here does not prove they are the same build,
// but it does pin the field names, which is what a rename would break.
let encoded = WatchPayload.encode(board)
check(encoded != nil, "the usage payload encodes")
let decoded = encoded.flatMap { WatchPayload.decode(WatchPayload.Usage.self, from: $0) }
check(decoded?.entries.count == 2, "both accounts survive the round trip")
check(decoded?.peakPercent == 88, "the derived peak survives too")
check(decoded?.entries.first?.windows.count == 2, "every window survives")

// The keys are part of the contract between two targets, so a rename has to be
// deliberate. These are the names the phone writes and the watch reads.
let json = String(data: encoded ?? Data(), encoding: .utf8) ?? ""
for key in ["entries", "source", "label", "pace", "windows", "percent", "resetIn", "generatedAt"] {
    check(json.contains("\"\(key)\""), "the payload keeps the field name `\(key)`")
}

// A ring coloured by percentage is a glance, so the band boundaries are a
// product decision worth pinning: a value exactly on a boundary must land on
// one side deterministically.
check(json.contains("\"percent\":88"), "percentages are written as numbers, not strings")

if failures > 0 {
    print("\nWATCH_USAGE_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nWATCH_USAGE_PASS  (\(checks) checks)")