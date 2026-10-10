import Foundation

// Which ways an image can arrive, driven directly.
//
// The rule that fails silently is *which rows appear in the sheet*: a Clipboard
// row with nothing on the clipboard opens onto "No image on the clipboard" and
// reads as a broken button, and a Camera row on a device without one does the
// same. `AttachmentSource.available` is Foundation-only so this can assert the
// list without a simulator, which is the only way to see it at all — a
// screenshot shows the rows that were drawn, never the one that should have
// been.

var failures = 0
var checks = 0
func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition { print("PASS  \(label)") }
    else { failures += 1; print("FAIL  \(label)") }
}

func sources(camera: Bool, clipboard: Bool) -> [AttachmentSource] {
    AttachmentSource.available(hasCamera: camera, hasClipboardImage: clipboard)
}

print("— what is offered —")

// Clipboard is the conditional one that matters: it is the source whose absence
// of content is indistinguishable from a broken row.
check(sources(camera: true, clipboard: true)
        == [.camera, .photoLibrary, .files, .clipboard],
      "with a camera and an image on the clipboard: all four")

check(sources(camera: false, clipboard: true) == [.photoLibrary, .files, .clipboard],
      "no camera: the camera row is dropped, the rest stay")
check(sources(camera: true, clipboard: false) == [.camera, .photoLibrary, .files],
      "nothing on the clipboard: no clipboard row")

// The empty-clipboard case is the whole reason this function exists, so it gets
// its own assertion rather than riding on the full-list one.
check(!sources(camera: true, clipboard: false).contains(.clipboard),
      "an empty clipboard never draws a clipboard row")
check(!sources(camera: false, clipboard: false).contains(.clipboard),
      "nor on a device without a camera")

print("\n— order and the always-present sources —")

// Clipboard is last because it is the incidental one — something already
// copied, not a deliberate pick.
check(sources(camera: true, clipboard: true).last == .clipboard, "clipboard sorts last")
check(sources(camera: true, clipboard: true).first == .camera, "camera sorts first")

// Files and Photo Library have no availability question: the photo picker is
// PHPicker (out of process, no permission) and Files is the document flow.
check(sources(camera: false, clipboard: false).contains(.files), "Files is always offered")
check(sources(camera: false, clipboard: false).contains(.photoLibrary),
      "so is the photo library — PHPicker needs no permission to be usable")

// Whatever the inputs, no source is ever offered twice.
let all = sources(camera: true, clipboard: true)
check(Set(all).count == all.count, "no source appears twice")

print("\n— labels and symbols —")
// The sheet's rows are read aloud and shown; a missing label or symbol is a
// blank row, not a crash, so both are asserted rather than assumed.
check(AttachmentSource.allCases.allSatisfy { !$0.label.isEmpty }, "every source has a label")
check(AttachmentSource.allCases.allSatisfy { !$0.symbol.isEmpty }, "and a symbol")
check(AttachmentSource.clipboard.label == "Clipboard", "the clipboard row says what it is")
check(AttachmentSource.allCases.count == 4, "there are four sources, no more")

if failures > 0 {
    print("\nATTACHMENT_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nATTACHMENT_PASS  (\(checks) checks)")