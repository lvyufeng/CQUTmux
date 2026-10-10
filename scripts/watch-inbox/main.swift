import Foundation

// Grouping the watch inbox by project.
//
// The rule that fails silently is *which items appear under which heading*: an
// item whose project is unset must still be shown (it is a waiting approval,
// not an empty cell), and a single group must not be given a header — a lone
// title over everything is noise. Both look like a layout choice in a
// screenshot, so they are asserted here against the shared payload code.

var failures = 0
var checks = 0
func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition { print("PASS  \(label)") }
    else { failures += 1; print("FAIL  \(label)") }
}

func item(_ id: Int, _ project: String, _ ageMinutes: Double? = nil) -> WatchPayload.Snapshot.Item {
    // A fixed reference date: the sort is on relative recency, and a clock read
    // would make an ordering check flake at a second boundary.
    let at = ageMinutes.map { Date(timeIntervalSince1970: 1_700_000_000 - $0 * 60) }
    return WatchPayload.Snapshot.Item(id: id, source: "Claude Code", title: "Bash",
                                      body: "ls", project: project, at: at)
}
func snapshot(_ items: [WatchPayload.Snapshot.Item]) -> WatchPayload.Snapshot {
    WatchPayload.Snapshot(items: items)
}

print("— grouping —")
let two = snapshot([item(1, "api"), item(2, "web"), item(3, "api")])
check(two.groups.count == 2, "two projects are two groups")
check(two.groups.map(\.title) == ["api", "web"],
      "with no timestamps, named groups fall back to name order")
check(two.groups.first(where: { $0.title == "api" })?.items.count == 2,
      "both items from api land in one group")
check(two.groups.first(where: { $0.title == "web" })?.items.count == 1,
      "the web item gets its own")
check(two.isGrouped, "two projects means the headers earn their row")

print("\n— an item with no project —")
let mixed = snapshot([item(1, ""), item(2, "api")])
check(mixed.groups.count == 2, "an item with no project is still shown, not dropped")
check(mixed.groups.last?.title == "", "and forms one unnamed group, sorted last")
check(mixed.groups.first?.title == "api", "with the named group ahead of it")

// Several items with no project are one group, not one group each.
let several = snapshot([item(1, ""), item(2, ""), item(3, "api")])
check(several.groups.count == 2, "items with no project share one group")

print("\n— headings run newest-first, as the phone's do —")
// The phone's board puts the group with the most recent activity first. The
// watch is a smaller version of the same board, so it says the same thing.
let ordered = snapshot([item(1, "old", 30), item(2, "recent", 1), item(3, "middle", 10)])
check(ordered.groups.map(\.title) == ["recent", "middle", "old"],
      "headings are ordered by the newest item in each")
check(ordered.groups.first?.items.first?.id == 2, "and the newest group's item leads")

// A group whose items carry no timestamp cannot claim to be recent; it must not
// be sorted above one that does.
let undated = snapshot([item(1, "dated", 5), item(2, "undated", nil)])
check(undated.groups.map(\.title) == ["dated", "undated"],
      "a group with no timestamp sorts below one that has a real one")

// The phone sorts leftovers last regardless of recency. A wrist that put them
// first would be leading with the items least likely to be actionable.
let leftovers = snapshot([item(1, "", 1), item(2, "api", 60)])
check(leftovers.groups.map(\.title) == ["api", ""],
      "the unnamed group is last even when its item is the newest")

// Two groups tied on recency: ordered by name, not by dictionary iteration.
let tied = snapshot([item(1, "zeta", 5), item(2, "alpha", 5)])
check(tied.groups.map(\.title) == ["alpha", "zeta"],
      "equally recent groups are ordered by name, not at random")

print("\n— one group needs no header —")
let one = snapshot([item(1, "api"), item(2, "api")])
check(one.groups.count == 1, "one project is one group")
check(!one.isGrouped, "which is not given a header")
check(!snapshot([item(1, ""), item(2, "")]).isGrouped,
      "nor is an all-unnamed list")
check(snapshot([]).groups.isEmpty, "no items is no group")
check(!snapshot([]).isGrouped, "and nothing for a header to say")

print("\n— grouping loses nothing —")
let all = [item(1, "api"), item(2, "web"), item(3, ""), item(4, "api")]
let grouped = snapshot(all)
check(grouped.groups.flatMap(\.items).count == all.count, "no item is dropped by grouping")
check(Set(grouped.groups.flatMap(\.items).map(\.id)) == Set([1, 2, 3, 4]),
      "every id is present exactly once")

print("\n— the tray tells the truth —")
// The one mark that says something is waiting must go quiet when nothing is.
check(WatchPayload.inboxGlyph(hasItems: true) == "tray.full", "a waiting inbox shows a full tray")
check(WatchPayload.inboxGlyph(hasItems: false) == "tray", "an empty inbox shows an empty one")
check(WatchPayload.inboxGlyph(hasItems: true) != WatchPayload.inboxGlyph(hasItems: false),
      "and the two are distinguishable, which a constant glyph would not be")

print("\n— the field travels —")
// The project name crosses as JSON. A rename on one side only is a silent
// no-grouping state on the wrist — every item would land in the unnamed group
// and the headers would never appear — so the round trip is pinned.
let encoded = try! JSONEncoder().encode(grouped)
let decoded = try! JSONDecoder().decode(WatchPayload.Snapshot.self, from: encoded)
check(decoded.items.first(where: { $0.id == 1 })?.project == "api", "project survives the wire")
check(decoded.groups.map(\.title) == grouped.groups.map(\.title),
      "and the grouping is the same after decoding")

if failures > 0 {
    print("\nWATCH_INBOX_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nWATCH_INBOX_PASS  (\(checks) checks)")
