import Foundation

// Transcription history: the cap, the de-duplication, and what is *not*
// recorded.
//
// The store is small and its rules are all invisible in the app. An off-by-one
// on the cap is the kind of thing nobody notices until the list quietly stops
// growing; a duplicate that is kept pushes a distinct entry off the end and
// looks like the app forgot something. Worst of all, this is a list of things
// the user said — so what it must *not* contain is part of the contract, and
// that part is stated here rather than left to be inferred from the code.

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

func fresh(_ name: String) -> TranscriptionHistory {
    let suite = "cqutmux.history.test.\(name)"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return TranscriptionHistory(store: UserDefaults(suiteName: suite)!)
}

// MARK: - The basics

let basic = fresh("basic")
check(basic.entries.isEmpty, "a fresh install has no history")

basic.record("run the tests")
check(basic.entries.count == 1, "a dictation is recorded")
check(basic.entries.first?.text == "run the tests", "the entry holds what was said")

basic.record("and fix what fails")
check(basic.entries.first?.text == "and fix what fails", "the newest entry is first")
check(basic.entries.last?.text == "run the tests", "the older entry moved down")

// MARK: - What is not recorded

// The contract that matters: this is dictated text only. The store is fed from
// the dictation callback rather than from the terminal's input path precisely
// so that a typed password cannot land here, and these two checks pin that a
// caller cannot get an empty or whitespace entry in by accident either.
let blanks = fresh("blanks")
blanks.record("")
blanks.record("   \n\t ")
check(blanks.entries.isEmpty, "empty and whitespace-only dictations are not recorded")

let trimmed = fresh("trimmed")
trimmed.record("  hello  ")
check(trimmed.entries.first?.text == "hello", "surrounding whitespace is trimmed")

// MARK: - De-duplication

// A repeat is common — "run the tests" again a few minutes later — and keeping
// both would push a distinct entry off a 20-item list to store the same string
// twice.
let dupes = fresh("dupes")
dupes.record("same")
dupes.record("same")
check(dupes.entries.count == 1, "a repeated dictation is not stored twice")

dupes.record("other")
dupes.record("same")
check(dupes.entries.count == 2, "repeating an older entry does not add a third")
check(dupes.entries.first?.text == "same",
      "repeating an older entry moves it to the top rather than duplicating it")

// Two different strings that differ only in whitespace are the same dictation.
let spacey = fresh("spacey")
spacey.record("hello")
spacey.record(" hello ")
check(spacey.entries.count == 1, "whitespace-only differences count as a repeat")

// MARK: - The cap

let capped = fresh("capped")
for index in 0..<(TranscriptionHistory.limit + 5) {
    capped.record("line \(index)")
}
check(capped.entries.count == TranscriptionHistory.limit,
      "the history is capped at \(TranscriptionHistory.limit)")
check(capped.entries.first?.text == "line \(TranscriptionHistory.limit + 4)",
      "the newest survives the cap")
check(!capped.entries.contains { $0.text == "line 0" },
      "the oldest is the one dropped")

// Exactly at the limit must not drop anything: an off-by-one here would lose an
// entry on every 20th dictation, which is invisible until someone looks.
let exact = fresh("exact")
for index in 0..<TranscriptionHistory.limit {
    exact.record("line \(index)")
}
check(exact.entries.count == TranscriptionHistory.limit, "the cap is not one short")
check(exact.entries.last?.text == "line 0", "nothing is dropped at exactly the cap")

// MARK: - Removal and clearing

let removing = fresh("removing")
removing.record("first")
removing.record("second")
let victim = removing.entries.last!
removing.remove(victim)
check(removing.entries.count == 1, "an entry can be removed")
check(!removing.entries.contains(victim), "the removed entry is the one that went")

removing.clear()
check(removing.entries.isEmpty, "the history can be cleared")

// MARK: - It survives a relaunch

let suite = "cqutmux.history.test.persist"
UserDefaults.standard.removePersistentDomain(forName: suite)
let defaults = UserDefaults(suiteName: suite)!
let writer = TranscriptionHistory(store: defaults)
writer.record("remembered")
writer.record("also remembered")

let reader = TranscriptionHistory(store: defaults)
check(reader.entries.count == 2, "the history survives a relaunch")
check(reader.entries.first?.text == "also remembered", "the order survives too")
check(reader.entries.last?.text == "remembered", "including the older entry")

// A relaunch must not resurrect a cleared history.
reader.clear()
check(TranscriptionHistory(store: defaults).entries.isEmpty, "clearing survives a relaunch")

// Corrupted storage must not crash or produce junk: the honest answer is to
// start empty rather than to show the user a decoding error they cannot act on.
defaults.set(Data("not json".utf8), forKey: "cqutmux.transcriptionHistory")
check(TranscriptionHistory(store: defaults).entries.isEmpty,
      "unreadable stored history degrades to empty rather than crashing")

if failures > 0 {
    print("\nHISTORY_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nHISTORY_PASS  (\(checks) checks)")