import Foundation

// The bundled theme gallery.
//
// The rule that matters is quiet in both directions: a gallery slug that does
// not match what `ThemeImport` derives from the theme's own name means importing
// a gallery entry and then re-fetching it by slug adds a *second* copy instead
// of updating the first — the list grows a duplicate every time, and nothing
// reports it. So every entry is parsed through the real parser and checked
// against the slug the gallery assigned.

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

let entries = ThemeGallery.entries
check(!entries.isEmpty, "the gallery has entries")

// MARK: - Every entry is a theme the parser accepts

// A gallery whose documents do not parse is a gallery whose every entry fails on
// tap, with nothing to say why. Each is parsed through the same `ThemeImport`
// the paste box uses, so a document that works here works there.
var parsed: [String: TerminalTheme] = [:]
for entry in entries {
    switch ThemeImport.parse(entry.json) {
    case .success(let theme):
        parsed[entry.slug] = theme
    case .failure(let failure):
        check(false, "gallery entry \(entry.slug) does not parse: \(failure)")
    }
}
check(parsed.count == entries.count, "every gallery entry parses")

// MARK: - The slug agrees with the parser

// The one rule that has to hold across the two files. `ThemeImport` derives an
// imported theme's id from its name; the gallery derives the slug the same way.
// If they ever disagree, a re-fetch by slug is a new theme, not an update.
for entry in entries {
    guard let theme = parsed[entry.slug] else { continue }
    check(theme.id == "imported-" + entry.slug,
          "\(entry.name): the imported id matches the gallery slug")
}

// And no two entries share a slug — two entries collapsing to one id would make
// the second overwrite the first on import.
let slugs = entries.map(\.slug)
check(Set(slugs).count == slugs.count, "no two entries share a slug")

// MARK: - Ids are unique and lowercase

check(slugs.allSatisfy { $0 == $0.lowercased() }, "slugs are lowercase")
check(slugs.allSatisfy { !$0.isEmpty }, "no slug is empty")
// A slug has no leading, trailing or doubled separators: the split-and-rejoin
// the rule uses would not produce them, and one that appeared anyway would mean
// the rule changed shape somewhere.
check(slugs.allSatisfy { !$0.hasPrefix("-") && !$0.hasSuffix("-") && !$0.contains("--") },
      "slugs have no stray separators")

// MARK: - The colours came through

// Spot-check that a document is not just parseable but carries what it says: the
// background the entry declares is the background the theme has, and the mode
// survived. A gallery of all-default themes would pass every check above.
let dracula = parsed["dracula"]
check(dracula?.background == "282a36", "Dracula's background came through")
check(dracula?.dark == true, "and its mode")
check(dracula?.ansi.count == 16, "and its sixteen colours")
let solarizedLight = parsed["solarized-light"]
check(solarizedLight?.dark == false, "a light theme reads as light")
check(solarizedLight?.background == "fdf6e3", "with its own background")

// The two spellings of the same palette are distinct entries, not one: they
// collapse to different slugs and so different ids.
check(parsed["solarized-dark"]?.background != parsed["solarized-light"]?.background,
      "the dark and light halves of a palette are separate themes")

// MARK: - The slug rule itself

// No entry in the catalogue has a doubled or leading separator, so the squashing
// step — collapse runs, drop the ends — is not exercised by any of them. These
// pin it directly: without them, a slug rule that merely substituted each
// non-alphanumeric character would pass every catalogue check, and the first
// theme named "Foo  Bar" (two spaces) or "-Foo-" would get an id `ThemeImport`
// does not derive, turning its re-import into a duplicate.
check(ThemeGallery.slug("A  B") == "a-b", "a doubled separator collapses to one")
check(ThemeGallery.slug("-Foo-") == "foo", "a leading and trailing separator is dropped")
check(ThemeGallery.slug("!!Wow!!") == "wow", "a run at both ends is dropped")
check(ThemeGallery.slug("Solarized Dark") == "solarized-dark", "a single space becomes one dash")
check(ThemeGallery.slug("already-a-slug") == "already-a-slug", "a slug is left alone")
// And it agrees with the parser on the same input, which is the agreement the
// whole catalogue check rests on.
check(ThemeGallery.slug("Foo  Bar") == "foo-bar", "the squashing is stable")

// MARK: - Lookup by slug

check(ThemeGallery.entry(slug: "dracula")?.name == "Dracula", "a slug looks up its entry")
check(ThemeGallery.entry(slug: "nope") == nil, "an unknown slug finds nothing")
// A re-fetch by slug returns the same document it would have returned before,
// which is what makes it a re-fetch rather than a new download.
check(ThemeGallery.entry(slug: "nord")?.json == ThemeGallery.entry(slug: "nord")?.json,
      "a slug returns a stable document")
check(ThemeGallery.entry(slug: "dracula")?.json != ThemeGallery.entry(slug: "nord")?.json,
      "and different slugs return different documents")

// MARK: - Search

check(ThemeGallery.search("").count == entries.count, "an empty search returns everything")
check(ThemeGallery.search("   ").count == entries.count, "a whitespace search returns everything")
check(ThemeGallery.search("dracula").map(\.slug) == ["dracula"], "a name finds its entry")
check(ThemeGallery.search("DRACULA").map(\.slug) == ["dracula"], "case does not matter")
// A slug typed by hand, with the separator a user would not guess, still lands.
check(ThemeGallery.search("solarizeddark").isEmpty == false, "a squashed query finds a spaced name")
check(ThemeGallery.search("solarized dark").contains { $0.slug == "solarized-dark" },
      "a spaced query finds the spaced name")
check(ThemeGallery.search("zzzznope").isEmpty, "a query matching nothing returns nothing")
// A hyphenated slug is the one query the squashed *name* cannot satisfy: the
// name "Solarized Dark" has a space where the slug has a dash, so neither
// `name.contains` nor the space-stripped form matches "solarized-dark". Only
// the slug branch does — which is what makes this the check that pins it.
check(ThemeGallery.search("solarized-dark").map(\.slug) == ["solarized-dark"],
      "a hyphenated slug query finds its entry through the slug, not the name")
check(ThemeGallery.search("catppuccin-mocha").map(\.slug) == ["catppuccin-mocha"],
      "and so does another")
check(ThemeGallery.search("dark").allSatisfy { $0.name.lowercased().contains("dark") || $0.slug.contains("dark") },
      "a partial query matches on name or slug only")

// MARK: - The version

// Bumped when the catalogue changes; a positive integer is all the rule needs.
check(ThemeGallery.version >= 1, "the catalogue carries a version")

if failures > 0 {
    print("\nTHEME_GALLERY_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nTHEME_GALLERY_PASS  (\(checks) checks)")
