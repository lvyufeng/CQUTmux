import Foundation

// The chat's Markdown splitter, checked without a simulator.
//
// Every rule here fails silently: a fence that opens but never closes renders
// as one prose blob with visible backticks, and the message merely *looks* like
// the agent wrote rubbish. That is the failure this check exists for, so the
// rules are driven with real messages rather than looked at on a screen.
//
// `ChatMarkdown.swift` is Foundation-only, so it runs here directly.

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

func segments(_ text: String) -> [ChatMarkdown.Segment] {
    ChatMarkdown.segments(in: text)
}

// MARK: - Prose

check(segments("just a sentence") == [.prose("just a sentence")],
      "plain text is one prose run")
check(segments("") == [], "an empty message has no segments")
check(segments("   \n\n  ") == [], "a whitespace-only message is nothing to draw")

// Inline markup is left in the prose for SwiftUI's Markdown to draw; the
// splitter's job is blocks, not spans.
check(segments("try **bold** and `code`") == [.prose("try **bold** and `code`")],
      "inline bold and inline code stay in the prose")

// MARK: - Fenced code

let swift = """
Here is the fix:

```swift
let x = 1
```

That should do it.
"""
check(segments(swift) == [
    .prose("Here is the fix:"),
    .code(language: "swift", body: "let x = 1"),
    .prose("That should do it."),
], "a swift fence splits into prose/code/prose")

// Two backticks are inline code, not a fence. CommonMark requires three, and a
// message that writes ``double`` on its own line must not have everything after
// it swallowed as a code block.
check(segments("``\nnot a fence\n``") == [.prose("``\nnot a fence\n``")],
      "two backticks are inline code, not a fence")

// A bare fence has no language. The distinction matters: the language picks the
// highlighting, and a block that claims `swift` when it was not given one would
// highlight the wrong thing or none.
check(segments("```\nplain\n```") == [.code(language: nil, body: "plain")],
      "a bare fence has no language")

// The info string can carry more than the language.
check(segments("```swift title=\"App.swift\"\nlet x = 1\n```") ==
      [.code(language: "swift", body: "let x = 1")],
      "only the first word of the info string is the language")

// An unclosed fence runs to the end of the message, per CommonMark. Falling
// back to prose would show the reader the backticks, which is the bug.
check(segments("before\n```\nnever closed") == [
    .prose("before"),
    .code(language: nil, body: "never closed"),
], "an unclosed fence runs to the end of the message")

// Blank lines inside code are the code's own layout and must survive.
check(segments("```\na\n\nb\n```") == [.code(language: nil, body: "a\n\nb")],
      "blank lines inside a code block are kept")

// MARK: - Fence characters

// A tilde fence is a fence. `~~~` is how you write a code block containing
// backticks, so recognising only backticks breaks exactly the messages that
// need the feature.
check(segments("~~~\n```\n~~~") == [.code(language: nil, body: "```")],
      "a tilde fence works and may contain backticks")

// The closing fence must use the *same* character. A ``` line inside a ~~~ block
// is content, not the end.
check(segments("~~~\na\n```\nb\n~~~") == [.code(language: nil, body: "a\n```\nb")],
      "a backtick fence inside a tilde block is content")

// And it must be at least as long. A ``` line does not close a ```` block,
// because the extra backtick is content.
check(segments("````\na\n```\nb\n````") == [.code(language: nil, body: "a\n```\nb")],
      "a three-backtick line does not close a four-backtick block")

// A *longer* closing fence is fine: at least as long, not exactly.
check(segments("```\na\n`````") == [.code(language: nil, body: "a")],
      "a longer closing fence still closes the block")

// MARK: - Indentation

// Up to three leading spaces is still a fence.
check(segments("   ```\na\n   ```") == [.code(language: nil, body: "a")],
      "a fence indented three spaces is a fence")

// Four makes it an indented code block — which is how a fence ends up shown to
// the reader instead of opening a block. This is the difference between correct
// rendering and a message full of stray backticks.
let indented = segments("    ```\na\n    ```")
check(indented == [.prose("    ```\na\n    ```")],
      "a fence indented four spaces is prose, not a fence")

// MARK: - Images

let withImage = "Look:\n\n![a screenshot](https://example.com/a.png)\n\nDone."
check(segments(withImage) == [
    .prose("Look:"),
    .image(url: "https://example.com/a.png", alt: "a screenshot"),
    .prose("Done."),
], "an inline image is lifted out of the prose")

// Alt text may be empty — that is still an image, not literal text.
check(segments("![](https://example.com/a.png)") ==
      [.image(url: "https://example.com/a.png", alt: "")],
      "an image with no alt text is still an image")

// The title after the URL is not part of the address. Leaving it on would make
// the app fetch `https://example.com/a.png "the title"`, which is not a URL.
check(segments("![alt](https://example.com/a.png \"the title\")") ==
      [.image(url: "https://example.com/a.png", alt: "alt")],
      "an image title is stripped from the URL")

// A URL with its own parentheses — a Wikipedia link, say — must not be cut at
// the first `)`. This is the one that silently truncates a working link.
check(segments("![wiki](https://en.wikipedia.org/wiki/Foo_(bar))") ==
      [.image(url: "https://en.wikipedia.org/wiki/Foo_(bar)", alt: "wiki")],
      "parentheses inside an image URL do not end it")

// `![` with no closing brackets is not an image; it is text, and showing it as
// text is correct rather than dropping it.
check(segments("see ![oops") == [.prose("see ![oops")],
      "an unterminated image is left as prose")
check(segments("see ![alt] no url") == [.prose("see ![alt] no url")],
      "an image whose URL bracket is missing is left as prose")

// MARK: - Mixing them

// The full shape: prose, code, an image and more prose, in order. A splitter
// that handled blocks but not images (or the reverse) passes the parts above
// and fails here.
let everything = """
Start **here**.

```python
print("hi")
```

![shot](https://x.test/s.png)

End.
"""
check(segments(everything) == [
    .prose("Start **here**."),
    .code(language: "python", body: "print(\"hi\")"),
    .image(url: "https://x.test/s.png", alt: "shot"),
    .prose("End."),
], "prose, code and an image split in order")

// Whatever the exact prose boundaries, the image must be its own segment and
// the code must not swallow it: those are the two things a reader would see
// rendered wrongly.
let mixed = segments(everything)
check(mixed.contains(.image(url: "https://x.test/s.png", alt: "shot")),
      "the image is a segment of its own, not text inside the prose")
check(mixed.contains(.code(language: "python", body: "print(\"hi\")")),
      "the code block is its own segment with its language")
check(mixed.filter { if case .image = $0 { return true } else { return false } }.count == 1,
      "the image appears exactly once")

// MARK: - Order is preserved

// The segments are the message in order. A splitter that grouped all the code
// first, say, would pass every single-segment check above and render a
// different message than the agent wrote.
let kinds: [String] = segments("a\n```\nb\n```\nc\n_view_\n```\nd\n```").map {
    switch $0 {
    case .prose: "p"
    case .code: "c"
    case .image: "i"
    }
}
check(kinds == ["p", "c", "p", "c"], "segments keep the order the blocks appear in: \(kinds)")

if failures > 0 {
    print("\nCHAT_MARKDOWN_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nCHAT_MARKDOWN_PASS  (\(checks) checks)")