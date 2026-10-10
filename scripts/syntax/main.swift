import Foundation

// What the highlighter colours, and what it must leave alone.
//
// The interesting cases are all "this marker is not where it looks like it is":
// a comment marker inside a string, a quote inside a comment, an escape that
// makes a quote not end a string, a shell single-quote whose backslash is
// literal. Each is checked by asking for the kind of the *token covering a given
// substring*, so a rule that paints the rest of the file one colour shows up as
// the wrong kind at a known position rather than as a diff nobody reads.

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

/// The kind of the single token whose text is exactly `needle`.
///
/// Exact match rather than containment, because the bug these checks exist for
/// is a token that *grew* to swallow the rest of the file — which containment
/// would still report as present.
func kind(_ source: String, _ language: SyntaxHighlighter.Language, of needle: String) -> SyntaxHighlighter.Kind? {
    SyntaxHighlighter.tokens(source, language: language).first { $0.text == needle }?.kind
}

/// The kind of the token covering the first character of `needle`.
///
/// Offset-based rather than exact-token, because adjacent plain runs are merged
/// — so a name and the whitespace around it are one token, and asking for a
/// token equal to `"x"` finds nothing. This is still the strong question: a
/// token that *grew* to swallow the rest of the file reports its kind at a
/// position that should be something else.
func kindAt(_ source: String, _ language: SyntaxHighlighter.Language, _ needle: String) -> SyntaxHighlighter.Kind? {
    guard let range = source.range(of: needle) else { return nil }
    let offset = source.distance(from: source.startIndex, to: range.lowerBound)
    var running = 0
    for token in SyntaxHighlighter.tokens(source, language: language) {
        let next = running + token.text.count
        if offset >= running, offset < next { return token.kind }
        running = next
    }
    return nil
}

/// Whether some token of this kind contains `needle`.
func has(_ source: String, _ language: SyntaxHighlighter.Language, _ needle: String, as kind: SyntaxHighlighter.Kind) -> Bool {
    SyntaxHighlighter.tokens(source, language: language).contains { $0.kind == kind && $0.text.contains(needle) }
}

// MARK: - The invariant that makes the plain fallback safe

// Whatever the tokenizer does, the tokens must reconstruct the input exactly.
// If they do not, the view loses or duplicates characters — and the loss is
// invisible, because the file still renders, just wrong.
let corpus: [(String, SyntaxHighlighter.Language)] = [
    ("let x = 1 // hi\n", .swift),
    ("/* unterminated\nmore\n", .cFamily),
    ("\"unterminated\nmore\n", .javascript),
    ("def f():\n    return 'a\\'b'\n", .python),
    ("x='it\\'s'\n", .shell),
    ("var s = \"a // b\"\n", .go),
    ("{\"a\": 1}\n", .json),
    ("key = \"value # not a comment\"\n", .toml),
    ("#!/bin/sh\n# comment\necho hi\n", .shell),
    ("", .swift),
    ("0x1f 1_000 3.14 1e-9 f64\n", .rust),
    ("-- sql comment\nSELECT 'x' FROM t\n", .sql),
    ("\n\n   \t\n", .swift),
    ("let 中文 = \"字符串\"\n", .swift),
]
for (source, language) in corpus {
    let rebuilt = SyntaxHighlighter.tokens(source, language: language).map(\.text).joined()
    check(rebuilt == source, "tokens reconstruct the input: \(source.prefix(20).debugDescription)")
}

// MARK: - Comments are not where they look

// A `//` inside a string is text. The failure is that everything after it on
// the line is painted as a comment.
check(kindAt("\"http://x\"\n", .javascript, "http://x") == .string,
      "a slash-slash inside a string does not start a comment")
check(!has("\"http://x\"\n", .javascript, "//x", as: .comment),
      "and nothing there is painted as a comment")

// A quote inside a comment opens nothing. This is the one that paints the whole
// rest of the file as a string when quotes are counted per line.
check(has("// it's fine\nlet a = 1\n", .javascript, "// it's fine", as: .comment),
      "an apostrophe in a comment stays inside the comment")
check(has("// it's fine\nlet a = 1\n", .javascript, "let", as: .keyword),
      "and the code after it is still parsed as code")
check(!has("// it's fine\nlet a = 1\n", .javascript, "'s fine", as: .string),
      "a comment's apostrophe does not open a string")

// A block comment spans lines and reaches its own end, not the line's.
check(has("a\n/* one\ntwo */\nb\n", .cFamily, "one\ntwo", as: .comment),
      "a block comment runs across lines")
check(has("a\n/* one\ntwo */\nb\n", .cFamily, "b", as: .plain),
      "and ends where its close is, not at the file's end")

// MARK: - Strings and escapes

// `\"` does not end a string. Counting quotes ends it here, one character early.
check(kind("\"a\\\"b\"\n", .swift, of: "\"a\\\"b\"") == .string,
      "an escaped quote does not end a string")

// `\\` before a quote: the quote *is* the end, because the backslash is escaped.
check(kind("\"a\\\\\" + x\n", .swift, of: "\"a\\\\\"") == .string,
      "an escaped backslash leaves the quote to end the string")

// A shell single-quoted string has no escapes: the backslash is a character and
// the string ends at the next quote. Treating it as escaped swallows the rest.
let shell = "x='a\\' && y\n"
check(kind(shell, .shell, of: "'a\\'") == .string,
      "a shell single-quoted string ends at the next quote, backslash or not")
check(kindAt(shell, .shell, "y") == .plain,
      "and the text after it is not painted as inside the string")

// A shell double-quoted string *does* escape.
check(kind("x=\"a\\\"b\" y\n", .shell, of: "\"a\\\"b\"") == .string,
      "a shell double-quoted string honours the escape")

// Triple quotes: an embedded newline does not end it, and a lone quote inside
// does not either.
let triple = "s = \"\"\"line\nstill \"in\" string\"\"\"\ncode\n"
check(has(triple, .python, "still \"in\" string", as: .string),
      "a triple-quoted string spans lines and holds lone quotes")
check(has(triple, .python, "code", as: .plain), "and ends at its own delimiter")

// MARK: - Nesting

// Swift nests block comments; C does not. With nesting off this ends the comment
// at the inner close and paints the rest as code; with it on where it should be
// off, the comment never ends.
let nested = "/* a /* b */ still */ code\n"
check(has(nested, .swift, "still", as: .comment), "a swift block comment nests")
check(has(nested, .swift, "code", as: .plain), "and closes only at the outer delimiter")
check(has(nested, .cFamily, "still", as: .plain),
      "a C block comment does not nest, so the inner close ends it")

// MARK: - Unterminated constructs reach the end of the file

// Not the end of the line: the language does not reset here, and a line-scoped
// scanner would paint the following lines as code.
check(kindAt("\"\"\"oops\nlet a = 1\n", .swift, "let") == .string,
      "an unterminated triple-quoted string runs to the end of the file")
check(has("/* oops\nlet a = 1\n", .cFamily, "let", as: .comment),
      "an unterminated block comment runs to the end of the file")

// MARK: - Keywords and identifiers

check(kind("let x = 1\n", .swift, of: "let") == .keyword, "a keyword is a keyword")
check(kindAt("let x = 1\n", .swift, "x") == .plain, "a name is not")
check(kind("let x = 1\n", .swift, of: "1") == .number, "a number is a number")
check(kind("let s = String()\n", .swift, of: "String") == .type, "a builtin type is a type")
// A type whose name ends in a digit, which pins that digits are identifier
// characters: dropping them from the identifier body splits `Int8` into a type
// `Int` and a stray `8`, and both halves still read as plausible tokens.
check(kind("let a: Int8 = 1\n", .swift, of: "Int8") == .type,
      "a type with a trailing digit is one token")

// A name containing a keyword is a name: matching on substrings would paint the
// tail of every identifier.
check(kindAt("let letter = 1\n", .swift, "letter") == .plain,
      "a word containing a keyword is not the keyword")

// A digit inside a name does not start a number.
check(kindAt("let from2 = 1\n", .swift, "from2") == .plain,
      "a name with a digit is one name")
// Stated as "no separate number token", because the offset lookup above would
// still report `from2` as plain if it had been split into `from` + `2`.
check(!SyntaxHighlighter.tokens("let from2 = 1\n", language: .swift)
        .contains { $0.kind == .number && $0.text == "2" },
      "and its digit is not emitted as a number")
check(kind("x[0] = 1\n", .swift, of: "0") == .number, "a digit after punctuation is a number")

// MARK: - Numbers

check(kind("1_000_000\n", .rust, of: "1_000_000") == .number, "digit separators stay one number")
check(kind("3.14\n", .swift, of: "3.14") == .number, "a decimal is one number")
// A dot with no digit after it is punctuation, not a decimal point: `0...5` is
// three dots after a zero, and absorbing the first would fold the range
// operator into the number.
check(kind("a[0...5]\n", .swift, of: "0") == .number,
      "a dot that is not followed by a digit stays out of the number")
check(kind("1e-9\n", .swift, of: "1e-9") == .number, "an exponent sign is part of the number")
// A trailing dot is a member access, not a decimal point; keeping it in the
// number would paint `.` and the method name as digits.
check(kindAt("obj.method\n", .swift, "method") == .plain,
      "a dot begins no number, so the name after it is a name")

// MARK: - Directives

check(has("#!/bin/sh\n", .shell, "#!/bin/sh", as: .directive), "a shebang is a directive")
check(has("#if DEBUG\n", .swift, "#if DEBUG", as: .directive), "a line-start hash is a directive")
// Only at the line start: a `#` after code is not a directive.
check(has("let a = 1 // #not\n", .swift, "#not", as: .comment),
      "a hash after code is inside the comment, not a directive")

// MARK: - Choosing a language, and declining to

check(SyntaxHighlighter.language(for: "src/main.swift") == .swift, "swift by extension")
check(SyntaxHighlighter.language(for: "a/b/Makefile") == .shell, "a Makefile is shell by name")
check(SyntaxHighlighter.language(for: "Dockerfile") == .shell, "a Dockerfile is shell by name")
check(SyntaxHighlighter.language(for: "x.rs") == .rust, "rust by extension")
check(SyntaxHighlighter.language(for: "weird.qqq") == nil, "an unknown extension has no language")
check(SyntaxHighlighter.language(for: "LICENSE") == nil, "an extensionless unknown is not guessed")

// An unknown type is left whole and plain: guessing would colour ordinary words
// as keywords, which reads as noise. The file still has to render.
let unknown = "let x = 1\n"
check(SyntaxHighlighter.tokens(unknown, path: "notes.qqq") == [.init(kind: .plain, text: unknown)],
      "an unknown extension renders the file as one plain run")

// MARK: - Limits

// Above the limit it is plain, but still whole — the view must not lose text
// just because the file is large.
let big = String(repeating: "let x = 1\n", count: SyntaxHighlighter.highlightLimit / 5)
let bigTokens = SyntaxHighlighter.tokens(big, path: "big.swift")
check(bigTokens.count == 1 && bigTokens[0].kind == .plain, "a file over the limit is drawn plain")
check(bigTokens[0].text == big, "and the plain run is the whole file")

// The two differ, and the difference is the languages': a TOML basic string
// must close on its own line, so a stray quote ends at the newline; a YAML
// quoted scalar may continue on the next line, so an unterminated one runs to
// the end of the document as a string.
check(kindAt("key = \"unterminated\nother = 1\n", .toml, "other") == .plain,
      "an unterminated toml string ends at the newline")
check(kindAt("key: \"unterminated\nother: 1\n", .yaml, "other") == .string,
      "an unterminated yaml scalar runs to the end of the document")

check(SyntaxHighlighter.tokens("", path: "a.swift").isEmpty, "an empty file has no tokens")

if failures > 0 {
    print("\nSYNTAX_FAIL  (\(failures) of \(checks) failed)")
    exit(1)
}
print("\nSYNTAX_PASS  (\(checks) checks)")
