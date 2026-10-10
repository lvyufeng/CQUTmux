import Foundation

// What the Lock Screen's buttons leave behind, and what the app does with it.
//
// The queue is where a wrong answer is invisible: a tap that never arrives
// looks exactly like a tap the user did not make, and the approval simply sits
// in "Needs you" — which is also what a working denial looks like. So the rules
// are here, apart from WidgetKit, and run against a scratch defaults suite.

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

let suite = "cqutmux.check.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }

let queue = MobileDecisionQueue(defaults: defaults)
let now = Date(timeIntervalSince1970: 1_700_000_000)

// MARK: - Round trip

check(queue.pending().isEmpty, "a fresh queue holds nothing")

check(queue.enqueue(MobileDecision(id: 7, allow: true, at: now)), "a decision is enqueued")
let stored = queue.pending()
check(stored.count == 1, "and reads back")
check(stored.first?.id == 7, "with its event id")
check(stored.first?.allow == true, "and its decision")
// The date is the reason the encode strategy is spelled out: the default
// encodes a reference-counted double, which a different decoder reads as an
// unrelated instant.
check(stored.first?.at == now, "and its timestamp, to the second")

// MARK: - Last write wins

// A user who taps Allow and then changes their mind must send one decision —
// the second. Appending would send a contradictory pair, and which one the host
// applied would depend on the order the array was read in.
queue.enqueue(MobileDecision(id: 7, allow: false, at: now.addingTimeInterval(5)))
check(queue.pending().count == 1, "a second decision for the same event replaces the first")
check(queue.pending().first?.allow == false, "and it is the later one that stands")

// Different events are separate decisions, not replacements.
queue.enqueue(MobileDecision(id: 8, allow: true, at: now.addingTimeInterval(1)))
check(queue.pending().count == 2, "a decision for another event is kept alongside")

// MARK: - Order

// Oldest first, so a queue drained after the app was away sends the decisions in
// the order they were made. Sorted rather than insertion-ordered because the
// replacement above rewrites in place — and it rewrote id 7's *time* to when the
// user changed their mind, so 7 is now the newer decision and comes second.
// Reading the ids off the array would have hidden that.
let ordered = queue.pending().map(\.id)
check(ordered == [8, 7], "decisions come back oldest first")

// MARK: - Drain

let drained = queue.drain()
check(drained.count == 2, "draining takes everything")
check(drained.map(\.id) == [8, 7], "in order")
check(queue.pending().isEmpty, "and leaves the queue empty")
// The one that matters: a queue that kept its contents would re-send every
// decision on every later connection, and a host recording five denials for one
// approval would be reading a queue that never emptied.
check(queue.drain().isEmpty, "draining again sends nothing")

// MARK: - Refusals

// Real event ids come from the gateway and are positive; the sample events the
// Settings button shows are negative on purpose. Writing one of those here would
// send a decision about an approval that does not exist.
check(!queue.enqueue(MobileDecision(id: -1, allow: true, at: now)),
      "a sample event's negative id is refused")
check(!queue.enqueue(MobileDecision(id: 0, allow: true, at: now)), "a zero id is refused")
check(queue.pending().isEmpty, "and neither is recorded")

// MARK: - A broken payload

// A queue that no longer decodes — written by an older version, or a partial
// write — has to read as empty. The alternative is a queue that throws on every
// read and can never be emptied, so the decisions behind it are stuck forever.
defaults.set(Data("not json".utf8), forKey: MobileDecisionQueue.storageKey)
check(queue.pending().isEmpty, "an undecodable payload reads as empty")
queue.enqueue(MobileDecision(id: 9, allow: true, at: now))
check(queue.pending().map(\.id) == [9], "and the queue still works after one")

// MARK: - No container

// A build without the App Group entitlement: the queue does nothing rather than
// crashing, which is the honest result — the Lock Screen buttons simply have
// nowhere to write.
let orphan = MobileDecisionQueue(defaults: nil)
check(orphan.pending().isEmpty, "a queue with no container reads empty")
check(!orphan.enqueue(MobileDecision(id: 1, allow: true, at: now)), "and refuses to enqueue")
check(orphan.drain().isEmpty, "and drains to nothing")

// MARK: - What the widget sends

// The app resolves a decision by id against the events it holds. The shape the
// widget writes is the shape the app reads, which is the one thing that has to
// be true across the two processes. The encoding is the queue's own — a bare
// `JSONEncoder` would use the deferred date strategy, and reading that back as
// ISO-8601 is the mismatch this check exists to catch, not to introduce.
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let encoded = try! encoder.encode([MobileDecision(id: 3, allow: false, at: now)])
defaults.set(encoded, forKey: MobileDecisionQueue.storageKey)
let back = queue.pending()
check(back.count == 1 && back[0].id == 3 && back[0].allow == false,
      "what the widget encodes is what the app reads")

if failures > 0 {
    print("\nMOBILE_DECISION_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nMOBILE_DECISION_PASS  (\(checks) checks)")
