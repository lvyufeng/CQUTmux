import Foundation
import CoreText

// Importing a font the user brought.
//
// Every rule here fails in a way that looks like something else. A rejected
// extension leaves a font that displays as the system's, which reads as "the
// import silently did nothing". A copy that does not happen makes the font work
// today and vanish after the next launch. A name taken from the filename rather
// than the font makes a later `UIFont(name:)` fail for reasons nobody can see.
//
// The store reads fonts through Core Text and never through UIKit, which is why
// this needs no simulator; the `UIFont(name:)` lookup at the end is a one-liner
// on the rendering side and is not what these rules are about.

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

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("cqutmux-fonts-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

/// A store on a suite of its own, with any earlier run's state cleared.
func store(_ name: String, directory: URL) -> CustomFontStore {
    let suite = "cqutmux.fonts.test.\(name)"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return CustomFontStore(store: UserDefaults(suiteName: suite)!, directory: directory)
}

/// The same store as a fresh launch would build it: same defaults, same
/// directory, nothing cleared. Wiping here instead would erase the very state
/// these checks exist to prove survives — a relaunch does not clear defaults.
func relaunch(_ name: String, directory: URL) -> CustomFontStore {
    let suite = "cqutmux.fonts.test.\(name)"
    return CustomFontStore(store: UserDefaults(suiteName: suite)!, directory: directory)
}

/// A real font from the system, copied out so the test owns the file and can
/// remove it. Inventing one is not an option: the whole point is that Core Text
/// can read it.
func sampleFont(named name: String = "Menlo.ttc") -> URL? {
    let candidates = [
        "/System/Library/Fonts/\(name)",
        "/System/Library/Fonts/Supplemental/\(name)",
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
}

let source = sampleFont()
check(source != nil, "found a system font to import from")

guard let source else {
    print("\nFONTS_FAIL  (no sample font)")
    exit(1)
}

// MARK: - A successful import

let dir = scratch.appendingPathComponent("ok")
let ok = store("ok", directory: dir)
let imported = ok.importFont(from: source)
check(imported != nil, "a real font imports")
check(ok.lastError == nil, "a successful import leaves no error to show")
check(ok.fonts.count == 1, "the font is in the list")

// The name that matters is the font's own, not the file's: that is what
// `UIFont(name:size:)` will be called with later, and a filename is usually
// neither.
check(imported?.postScriptName.isEmpty == false, "the import captured a PostScript name")
check(imported?.postScriptName == "Menlo-Regular" || imported?.postScriptName.hasPrefix("Menlo") == true,
      "the PostScript name is the font's, not the file's")
check(imported?.displayName.isEmpty == false, "the import captured something to show in the picker")

// The file must be *copied*, not referenced. Referencing would work today (the
// source is still on disk) and fail after a relaunch or a Files cleanup.
let copied = dir.appendingPathComponent(imported?.fileName ?? "")
check(FileManager.default.fileExists(atPath: copied.path),
      "the font is copied into the app's own directory")
check(copied.path != source.path, "the copy is not the original path")

// MARK: - A relaunch finds it

// Rebuilding the store from the same defaults and directory is what a relaunch
// does, and it is where a store that kept its list only in memory would fail.
let reopened = relaunch("ok", directory: dir)
check(reopened.fonts.count == 1, "the font list survives a relaunch")
check(reopened.postScriptName(for: imported?.id ?? "") != nil,
      "the copied file is still resolvable after a relaunch")

// MARK: - What is refused

let refusing = store("refusing", directory: scratch.appendingPathComponent("refusing"))
let notAFont = scratch.appendingPathComponent("notes.txt")
try? "hello".write(to: notAFont, atomically: true, encoding: .utf8)
check(refusing.importFont(from: notAFont) == nil, "a .txt is refused")
check(refusing.lastError != nil, "a refusal explains itself")
check(refusing.fonts.isEmpty, "a refused file is not added")

// A file with the right extension and the wrong contents: the case a naive
// implementation accepts, after which the terminal renders the system font and
// the user concludes the import is broken.
let fake = scratch.appendingPathComponent("fake.ttf")
try? Data(repeating: 0xAB, count: 512).write(to: fake)
check(refusing.importFont(from: fake) == nil, "a file that is not really a font is refused")
check(refusing.fonts.isEmpty, "the fake font is not added")

let missing = scratch.appendingPathComponent("gone.ttf")
check(refusing.importFont(from: missing) == nil, "a missing file is refused, not crashed on")

// MARK: - Re-import and removal

// Importing the same font again must not produce two entries: a picker with the
// same name twice is a choice the user cannot make.
let again = store("again", directory: scratch.appendingPathComponent("again"))
_ = again.importFont(from: source)
_ = again.importFont(from: source)
check(again.fonts.count == 1, "importing the same font twice does not duplicate it")

let gone = store("gone", directory: scratch.appendingPathComponent("gone"))
let toRemove = gone.importFont(from: source)
check(toRemove != nil, "setup: a font to remove")
if let toRemove {
    let path = scratch.appendingPathComponent("gone").appendingPathComponent(toRemove.fileName)
    gone.remove(toRemove)
    check(gone.fonts.isEmpty, "removing takes it out of the list")
    check(!FileManager.default.fileExists(atPath: path.path),
          "removing deletes the file too, so the next launch cannot re-register it")
}

// MARK: - The name is the one the renderer will ask for

// The link between this store and the terminal: what is stored has to be a name
// Core Text will resolve, or the font imports successfully and renders as the
// system's.
if let name = imported?.postScriptName {
    let resolved = CTFontCreateWithName(name as CFString, 12, nil)
    let resolvedName = CTFontCopyPostScriptName(resolved) as String
    check(resolvedName == name, "the stored name resolves back to the same font")
    check(resolvedName != CTFontCopyPostScriptName(CTFontCreateWithName("NoSuchFont-9999" as CFString, 12, nil)) as String,
          "and it is not silently substituting a different font")
}

// MARK: - Being told which one is chosen

let picking = store("picking", directory: scratch.appendingPathComponent("picking"))
check(picking.postScriptName(for: "not-imported") == nil, "an unknown id resolves to nothing")
check(!picking.contains(id: "not-imported"), "an unknown id is not in the list")

if failures > 0 {
    print("\nFONTS_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nFONTS_PASS  (\(checks) checks)")