import Foundation

/// Splitting source into coloured runs.
///
/// A lexer, not a parser, and deliberately shallow: it knows about comments,
/// strings, numbers and keywords, and nothing about what the code means. That
/// is the right depth for a read-only viewer — a real grammar per language would
/// be a dependency and a per-file parse on a phone.
///
/// The rules it does implement are the ones that fail *quietly*, and every one
/// of them fails the same way: the rest of the file is painted the wrong colour
/// and no error appears. So the scanner runs as one pass with a mode, never as
/// per-line regexes:
///
///   - A `//` inside a string is text, not a comment. Painting to end-of-line as
///     a comment hides the rest of the line.
///   - A quote inside a comment opens nothing. Scanning with regexes per line
///     makes an apostrophe in a comment swallow the file as an unterminated
///     string.
///   - `\"` and `\\` do not end a string; counting quotes rather than honouring
///     escapes ends the string one character early or late.
///   - A single-quoted shell string has **no** escapes — `'it\'` ends at the
///     second quote — while a double-quoted one does.
///   - An unterminated block comment or triple-quoted string reaches the end of
///     the file rather than resetting at the next line, because that is what the
///     language does.
///   - Swift block comments **nest**; C's do not.
///
/// Foundation-only, so the whole thing is checked without a simulator.
enum SyntaxHighlighter {
    enum Kind: Equatable {
        case plain
        case keyword
        case type
        case string
        case comment
        case number
        /// A preprocessor line or a shebang — `#if`, `#!/bin/sh`, `%YAML`.
        case directive
    }

    struct Token: Equatable {
        var kind: Kind
        var text: String
    }

    /// The languages worth a table. Anything else is drawn as plain text rather
    /// than guessed at: a wrong guess colours ordinary words as keywords, which
    /// reads as noise, while plain text is merely unhelpful.
    enum Language: String {
        case swift, cFamily, javascript, python, shell, go, rust, ruby, json, yaml, toml, sql
    }

    // MARK: - Detection

    /// The language for a path, or nil to leave it plain.
    ///
    /// Extension first, then a handful of extensionless names that carry their
    /// own language. `Makefile` and `Dockerfile` are matched by name because
    /// their syntax is not any of the above.
    static func language(for path: String) -> Language? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "makefile", "gnumakefile", "dockerfile", "containerfile", "rakefile", "gemfile":
            return .shell
        case ".gitignore", ".gitattributes", ".dockerignore", ".editorconfig", ".env":
            return .shell
        default: break
        }
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return .swift
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "java", "kt", "kts", "scala", "cs":
            return .cFamily
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts": return .javascript
        case "py", "pyi", "pyw": return .python
        case "sh", "bash", "zsh", "ksh", "fish", "bashrc", "zshrc", "bash_profile", "profile":
            return .shell
        case "go": return .go
        case "rs": return .rust
        case "rb", "gemspec": return .ruby
        case "json", "jsonc", "geojson": return .json
        case "yml", "yaml": return .yaml
        case "toml": return .toml
        case "sql": return .sql
        default: return nil
        }
    }

    // MARK: - Entry

    /// Above this the file is drawn plain. Tokenising a megabyte of minified
    /// JavaScript into an attributed string would stall the scroll for a file
    /// nobody reads at that size.
    static let highlightLimit = 200_000

    /// The whole file as coloured runs.
    ///
    /// The tokens always cover the input exactly — `tokens.map(\.text).joined()
    /// == source` — so the view can render them without losing or duplicating a
    /// character, which is the property that makes the plain fallback safe.
    static func tokens(_ source: String, path: String) -> [Token] {
        guard source.count <= highlightLimit, let language = language(for: path) else {
            return source.isEmpty ? [] : [Token(kind: .plain, text: source)]
        }
        return tokens(source, language: language)
    }

    static func tokens(_ source: String, language: Language) -> [Token] {
        let spec = Spec(language)
        var scanner = Scanner(source, spec)
        return scanner.run()
    }

    // MARK: - Per-language rules

    /// How one language's syntax reads. A table rather than a switch inside the
    /// scanner, because the scanner's job is to honour escapes and nesting; the
    /// table's job is to say which of them a language has.
    struct Spec {
        var lineComments: [String] = []
        var blockOpen: String?
        var blockClose: String?
        var blockNests = false
        /// Characters that begin a string, and whether what follows is escaped
        /// inside them. Shell's `'` is the case that makes this a pair of
        /// lists rather than a set.
        var escapedQuotes: [Character] = []
        var literalQuotes: [Character] = []
        /// Whether a quote begins a three-character delimiter (`"""`, `'''`).
        var tripleQuotes = false
        /// Whether a newline ends a plain string. True everywhere except where
        /// a language allows raw newlines inside ordinary quotes.
        var newlineEndsString = true
        /// A `#` (or `%`) only at the start of a line, as in Swift's `#if`.
        var linePrefixDirectives: [String] = []
        var keywords: Set<String> = []
        var types: Set<String> = []

        init(_ language: Language) {
            switch language {
            case .swift:
                lineComments = ["//"]
                blockOpen = "/*"; blockClose = "*/"; blockNests = true
                escapedQuotes = ["\""]
                tripleQuotes = true
                linePrefixDirectives = ["#"]
                keywords = Self.swiftKeywords
                types = Self.swiftTypes
            case .cFamily:
                lineComments = ["//"]
                blockOpen = "/*"; blockClose = "*/"
                escapedQuotes = ["\"", "'"]
                linePrefixDirectives = ["#"]
                keywords = Self.cKeywords
                types = Self.cTypes
            case .javascript:
                lineComments = ["//"]
                blockOpen = "/*"; blockClose = "*/"
                // Backticks span lines in a template literal, so they are the
                // one quote here that a newline does not close.
                escapedQuotes = ["\"", "'", "`"]
                keywords = Self.jsKeywords
                types = Self.jsTypes
            case .python:
                lineComments = ["#"]
                escapedQuotes = ["\"", "'"]
                tripleQuotes = true
                keywords = Self.pythonKeywords
                types = Self.pythonTypes
            case .shell:
                lineComments = ["#"]
                escapedQuotes = ["\""]
                literalQuotes = ["'", "`"]
                linePrefixDirectives = ["#!"]
                keywords = Self.shellKeywords
            case .go:
                lineComments = ["//"]
                blockOpen = "/*"; blockClose = "*/"
                escapedQuotes = ["\"", "'", "`"]
                keywords = Self.goKeywords
                types = Self.goTypes
            case .rust:
                lineComments = ["//"]
                blockOpen = "/*"; blockClose = "*/"; blockNests = true
                escapedQuotes = ["\""]
                keywords = Self.rustKeywords
                types = Self.rustTypes
            case .ruby:
                lineComments = ["#"]
                escapedQuotes = ["\""]
                literalQuotes = ["'"]
                keywords = Self.rubyKeywords
            case .json:
                escapedQuotes = ["\""]
                newlineEndsString = false
            case .yaml:
                lineComments = ["#"]
                escapedQuotes = ["\""]
                literalQuotes = ["'"]
                // A YAML quoted scalar may continue on the next line, so an
                // unterminated one runs to the end of the document as a string —
                // the same rule as an unterminated Python triple-quote, and not
                // a reset at the newline.
                newlineEndsString = false
            case .toml:
                lineComments = ["#"]
                escapedQuotes = ["\""]
                literalQuotes = ["'"]
                // A TOML basic string must close on its own line (multi-line
                // values use the triple-quoted form), so a stray quote ends at
                // the newline rather than swallowing the rest of the file.
                newlineEndsString = true
            case .sql:
                lineComments = ["--"]
                blockOpen = "/*"; blockClose = "*/"
                literalQuotes = ["'"]
                escapedQuotes = ["\""]
                keywords = Self.sqlKeywords
            }
        }

        static let swiftKeywords: Set<String> = [
            "actor", "any", "as", "associatedtype", "async", "await", "borrowing", "break",
            "case", "catch", "class", "consume", "consuming", "continue", "convenience",
            "copy", "default", "defer", "deinit", "didSet", "distributed", "do", "dynamic",
            "each", "else", "enum", "extension", "fallthrough", "fileprivate", "final",
            "for", "func", "get", "guard", "if", "import", "in", "indirect", "infix",
            "init", "inout", "internal", "is", "isolated", "lazy", "left", "let", "macro",
            "mutating", "nonisolated", "nonmutating", "open", "operator", "optional",
            "override", "package", "postfix", "precedencegroup", "prefix", "private",
            "protocol", "public", "repeat", "required", "rethrows", "return", "right",
            "self", "set", "some", "static", "struct", "subscript", "super", "switch",
            "throws", "try", "typealias", "var", "weak", "where", "while", "willSet",
            "true", "false", "nil",
        ]
        static let swiftTypes: Set<String> = [
            "Any", "AnyObject", "Array", "Bool", "Character", "Data", "Dictionary",
            "Double", "Error", "Float", "Int", "Int8", "Int16", "Int32", "Int64",
            "Never", "Optional", "Result", "Set", "String", "Substring", "UInt",
            "UInt8", "UInt16", "UInt32", "UInt64", "URL", "Void",
        ]
        static let cKeywords: Set<String> = [
            "alignas", "alignof", "auto", "break", "case", "catch", "class", "const",
            "constexpr", "continue", "default", "delete", "do", "else", "enum", "explicit",
            "export", "extern", "final", "for", "friend", "goto", "if", "import", "inline",
            "mutable", "namespace", "new", "noexcept", "nullptr", "operator", "override",
            "private", "protected", "public", "register", "return", "sizeof", "static",
            "struct", "switch", "template", "this", "throw", "try", "typedef", "typename",
            "union", "using", "virtual", "volatile", "while", "true", "false",
        ]
        static let cTypes: Set<String> = [
            "bool", "char", "double", "float", "int", "long", "short", "signed",
            "size_t", "ssize_t", "string", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
            "unsigned", "void", "wchar_t",
        ]
        static let jsKeywords: Set<String> = [
            "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
            "debugger", "default", "delete", "do", "else", "enum", "export", "extends",
            "finally", "for", "function", "get", "if", "implements", "import", "in",
            "instanceof", "interface", "let", "new", "of", "package", "return", "set",
            "static", "super", "switch", "this", "throw", "try", "type", "typeof", "var",
            "void", "while", "with", "yield", "true", "false", "null", "undefined",
        ]
        static let jsTypes: Set<String> = [
            "Array", "Boolean", "Date", "Error", "JSON", "Map", "Math", "Number",
            "Object", "Promise", "RegExp", "Set", "String", "Symbol", "WeakMap", "WeakSet",
        ]
        static let pythonKeywords: Set<String> = [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
            "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
            "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
            "return", "try", "while", "with", "yield", "True", "False", "None", "match",
            "case", "self", "cls",
        ]
        static let pythonTypes: Set<String> = [
            "bool", "bytes", "dict", "float", "frozenset", "int", "list", "object",
            "set", "str", "tuple", "type",
        ]
        static let shellKeywords: Set<String> = [
            "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if",
            "in", "local", "return", "select", "then", "time", "until", "while", "export",
            "readonly", "declare", "unset", "shift", "eval", "exec", "source", "alias",
        ]
        static let goKeywords: Set<String> = [
            "break", "case", "chan", "const", "continue", "default", "defer", "else",
            "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
            "package", "range", "return", "select", "struct", "switch", "type", "var",
            "true", "false", "nil",
        ]
        static let goTypes: Set<String> = [
            "bool", "byte", "complex64", "complex128", "error", "float32", "float64",
            "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8",
            "uint16", "uint32", "uint64", "uintptr",
        ]
        static let rustKeywords: Set<String> = [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
            "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match",
            "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
            "struct", "super", "trait", "type", "unsafe", "use", "where", "while",
            "true", "false",
        ]
        static let rustTypes: Set<String> = [
            "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize",
            "str", "u8", "u16", "u32", "u64", "u128", "usize", "String", "Vec", "Option",
            "Result", "Box",
        ]
        static let rubyKeywords: Set<String> = [
            "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do",
            "else", "elsif", "end", "ensure", "for", "if", "in", "module", "next", "not",
            "or", "redo", "rescue", "retry", "return", "self", "super", "then", "undef",
            "unless", "until", "when", "while", "yield", "true", "false", "nil", "require",
        ]
        static let sqlKeywords: Set<String> = [
            "add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case",
            "cast", "check", "column", "commit", "constraint", "create", "cross", "delete",
            "desc", "distinct", "drop", "else", "end", "exists", "foreign", "from", "full",
            "group", "having", "if", "in", "index", "inner", "insert", "into", "is", "join",
            "key", "left", "like", "limit", "not", "null", "offset", "on", "or", "order",
            "outer", "primary", "references", "right", "rollback", "select", "set", "table",
            "then", "union", "unique", "update", "values", "when", "where", "with",
        ]
    }

    // MARK: - The scanner

    /// One forward pass with a mode, over characters rather than lines.
    ///
    /// A line-at-a-time scan cannot express "the `//` is inside a string" or a
    /// block comment that spans lines, which are precisely the cases the caller
    /// must not get wrong, so the state carries across the whole file.
    private struct Scanner {
        private let chars: [Character]
        private let spec: Spec
        private var i = 0
        private var out: [Token] = []
        /// Whether only whitespace has been seen on this line, which is what
        /// makes `#if` a directive and a `#` mid-line something else.
        private var atLineStart = true

        init(_ source: String, _ spec: Spec) {
            chars = Array(source)
            self.spec = spec
        }

        mutating func run() -> [Token] {
            while i < chars.count {
                let start = i
                scanOne()
                // A step that consumed nothing would spin forever; the branches
                // below always advance, and this is the assertion of it.
                if i == start { i += 1 }
            }
            return out
        }

        private mutating func scanOne() {
            let c = chars[i]

            // Line-start directives are checked before comments so a shebang is
            // a directive rather than a comment.
            if atLineStart {
                for prefix in spec.linePrefixDirectives where matches(prefix) {
                    emit(.directive, to: endOfLine())
                    return
                }
            }
            for marker in spec.lineComments where matches(marker) {
                emit(.comment, to: endOfLine())
                return
            }
            if let open = spec.blockOpen, let close = spec.blockClose, matches(open) {
                emit(.comment, to: endOfBlockComment(open: open, close: close))
                return
            }
            if spec.escapedQuotes.contains(c) {
                emit(.string, to: endOfString(quote: c, escaped: true))
                return
            }
            if spec.literalQuotes.contains(c) {
                emit(.string, to: endOfString(quote: c, escaped: false))
                return
            }
            // No "is this digit part of a name?" test is needed here: the word
            // scanner consumes trailing digits, so a digit is only ever reached
            // at a step boundary when the character before it is not an
            // identifier character. A guard for that would be unreachable.
            if c.isNumber {
                emit(.number, to: endOfNumber())
                return
            }
            if isIdentifierStart(c) {
                let end = endOfWord()
                let word = String(chars[i..<end])
                let kind: Kind = spec.keywords.contains(word) ? .keyword
                    : (spec.types.contains(word) ? .type : .plain)
                emit(kind, to: end)
                return
            }
            // Anything else, one character at a time; adjacent plain characters
            // are merged by `emit` so the token list stays small.
            emit(.plain, to: i + 1)
        }

        // MARK: Emission

        private mutating func emit(_ kind: Kind, to end: Int) {
            let stop = min(max(end, i), chars.count)
            guard stop > i else { return }
            let text = String(chars[i..<stop])
            // Merged with the previous run when the kind matches, so punctuation
            // and whitespace do not become thousands of one-character tokens.
            if var last = out.last, last.kind == kind {
                last.text += text
                out[out.count - 1] = last
            } else {
                out.append(Token(kind: kind, text: text))
            }
            updateLineStart(over: i..<stop)
            i = stop
        }

        /// Whether the scanner is still before the first non-whitespace
        /// character of a line, which is what makes a `#` a directive rather
        /// than an operator.
        private mutating func updateLineStart(over range: Range<Int>) {
            for index in range {
                let c = chars[index]
                if c == "\n" { atLineStart = true }
                else if !c.isWhitespace { atLineStart = false }
            }
        }

        // MARK: Reading

        private func matches(_ marker: String) -> Bool {
            let m = Array(marker)
            guard i + m.count <= chars.count else { return false }
            for (offset, c) in m.enumerated() where chars[i + offset] != c { return false }
            return true
        }

        private func endOfLine() -> Int {
            var j = i
            while j < chars.count, chars[j] != "\n" { j += 1 }
            return j
        }

        /// The end of a string, honouring escapes and trying the triple-quoted
        /// form first when the language has one.
        private func endOfString(quote: Character, escaped: Bool) -> Int {
            var j = i + 1
            if spec.tripleQuotes, escaped, j + 1 < chars.count,
               chars[j] == quote, chars[j + 1] == quote {
                j += 2
                while j < chars.count {
                    if chars[j] == quote, j + 2 < chars.count,
                       chars[j + 1] == quote, chars[j + 2] == quote {
                        return j + 3
                    }
                    if escaped, chars[j] == "\\" { j += 2; continue }
                    j += 1
                }
                // Unterminated: the language runs it to the end of the file, and
                // resetting at the next line would paint code as a string.
                return chars.count
            }
            while j < chars.count {
                let c = chars[j]
                if c == "\\", escaped {
                    // The escaped character is part of the string whatever it
                    // is, including the quote that would otherwise end it.
                    j += 2
                    continue
                }
                if c == quote { return j + 1 }
                if c == "\n", spec.newlineEndsString { return j }
                j += 1
            }
            return chars.count
        }

        /// The end of a block comment, respecting nesting when the language has
        /// it. An unterminated one reaches the end of the file.
        private func endOfBlockComment(open: String, close: String) -> Int {
            var j = i + open.count
            var depth = 1
            while j < chars.count {
                if spec.blockNests, matchesAt(j, open) { depth += 1; j += open.count; continue }
                if matchesAt(j, close) {
                    depth -= 1
                    j += close.count
                    if depth == 0 { return j }
                    continue
                }
                j += 1
            }
            return chars.count
        }

        private func matchesAt(_ index: Int, _ marker: String) -> Bool {
            let m = Array(marker)
            guard index + m.count <= chars.count else { return false }
            for (offset, c) in m.enumerated() where chars[index + offset] != c { return false }
            return true
        }

        /// A number, kept deliberately loose: digits, one decimal point, and an
        /// exponent or a unit suffix. Being strict about `0x`, `_` separators
        /// and `f64` suffixes would leave most real literals half-painted, which
        /// looks worse than treating them as one number.
        private func endOfNumber() -> Int {
            var j = i
            var seenDot = false
            var seenExponent = false
            while j < chars.count {
                let c = chars[j]
                if c.isNumber || c == "_" {
                    j += 1
                } else if c == ".", !seenDot, !seenExponent,
                          j + 1 < chars.count, chars[j + 1].isNumber {
                    seenDot = true
                    j += 1
                } else if (c == "e" || c == "E" || c == "p" || c == "P"), !seenExponent,
                          j + 1 < chars.count,
                          chars[j + 1].isNumber
                            || ((chars[j + 1] == "+" || chars[j + 1] == "-")
                                && j + 2 < chars.count && chars[j + 2].isNumber) {
                    seenExponent = true
                    j += 1
                    if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                } else {
                    break
                }
            }
            return j
        }

        private func endOfWord() -> Int {
            var j = i
            while j < chars.count, isIdentifierBody(chars[j]) { j += 1 }
            return j
        }

        private func isIdentifierStart(_ c: Character) -> Bool {
            c.isLetter || c == "_" || c == "$" || c == "@"
        }

        private func isIdentifierBody(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "$" || c == "@"
        }
    }
}
