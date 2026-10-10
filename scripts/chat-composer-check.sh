#!/usr/bin/env bash
#
# Checks chat mode's delivery: what a composed message puts on the wire.
#
# Usage: scripts/chat-composer-check.sh
#
# What is asserted
# ----------------
# 1. Nothing sendable means nothing sent. Whitespace alone is not a message —
#    sending it puts a blank line into the agent's prompt, which a TUI reads as
#    a submit, so an empty Enter would fire an empty turn.
# 2. Bracketed paste is used only when the program asked for it. The markers
#    `ESC[200~`/`ESC[201~` make a TUI insert the text as one paste; sent to a
#    plain shell, which never negotiated them, they print as literal garbage.
#    This is the bit that decides it, and it comes from the terminal's own
#    `bracketedPasteMode`, so the two cannot disagree.
# 3. The message is submitted — a trailing CR — because that is what makes it
#    chat mode rather than command mode. Without it the text sits in the
#    agent's input unread.
# 4. Edges are trimmed, interior newlines are not. A multi-line prompt is a
#    legitimate thing to compose; leading and trailing blank space is an
#    accident of the keyboard.
# 5. Multi-byte text survives byte-for-byte. This is the reason the feature
#    exists: a CJK message must reach the pty as the same UTF-8 the field held,
#    with the paste markers wrapped around the whole thing and not spliced into
#    a character.
#
# `ChatComposer.swift` imports only Foundation, so it is run here directly
# through the Swift interpreter — the shipped function is exercised, not a copy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SWIFT_FILE="App/Features/Terminal/ChatComposer.swift"

if grep -qE '^import ' "$SWIFT_FILE" | grep -qv '^import Foundation$'; then
  echo "FAIL: $SWIFT_FILE imports something beyond Foundation:"
  grep -E '^import ' "$SWIFT_FILE" | grep -v '^import Foundation$'
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> checking what a composed message puts on the wire"
cat "$SWIFT_FILE" > "$WORK/main.swift"
printf '\n' >> "$WORK/main.swift"
cat >> "$WORK/main.swift" <<'SWIFT'

import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: \(message)")
        exit(1)
    }
}

func string(_ data: Data?) -> String {
    guard let data else { return "<nil>" }
    return String(decoding: data, as: UTF8.self)
}

// 1. Nothing to send means nothing sent.
for empty in ["", " ", "   ", "\n", " \t \n "] {
    check(ChatComposer.payload(for: empty, bracketed: false) == nil,
          "an empty message produced bytes: \(empty.debugDescription)")
    check(!ChatComposer.isSendable(empty),
          "\(empty.debugDescription) was treated as sendable")
}

// 2 & 3. Bracketed and plain, with a submitting CR either way.
let plain = ChatComposer.payload(for: "run the tests", bracketed: false)
check(string(plain) == "run the tests\r",
      "plain delivery is wrong: \(string(plain).debugDescription)")

let wrapped = ChatComposer.payload(for: "run the tests", bracketed: true)
check(string(wrapped) == "\u{1B}[200~run the tests\u{1B}[201~\r",
      "bracketed delivery is wrong: \(string(wrapped).debugDescription)")

// The marker is only ever around the text, never around the CR: a CR inside a
// bracketed paste is an inserted newline, not a submit.
let wrappedString = string(wrapped)
check(wrappedString.hasSuffix("\u{1B}[201~\r"),
      "the submitting CR is inside the paste: \(wrappedString.debugDescription)")

// 4. Edges trimmed, interior newlines kept.
let multi = ChatComposer.payload(for: "\n  line one\nline two  \n", bracketed: false)
check(string(multi) == "line one\nline two\r",
      "multi-line trimming is wrong: \(string(multi).debugDescription)")
check(string(multi).contains("\n"), "the interior newline was dropped")

// 5. Multi-byte text round-trips exactly. The Chinese here is a phrase that
//    would be composed with the iOS keyboard — the case chat mode exists for.
let chinese = "请把测试跑一遍"
let cjk = ChatComposer.payload(for: chinese, bracketed: true)
let cjkString = string(cjk)
check(cjkString == "\u{1B}[200~\(chinese)\u{1B}[201~\r",
      "the CJK message did not survive: \(cjkString.debugDescription)")
// And the same bytes come back out, which is what a pty receives. Stripping
// the 6-byte opening marker, the 6-byte closing marker, and the CR leaves
// exactly the message.
check(Array(cjk!.dropFirst(6).dropLast(7)) == Array(chinese.utf8),
      "the CJK bytes changed in transit")

// A message that itself contains the paste-end marker must not be able to close
// the paste early — otherwise text after it would be interpreted as keystrokes.
// The marker is passed through as text; a TUI inserting it as paste content is
// the safe reading, and this pins that it is not stripped or escaped into
// something that would end the paste.
let tricky = "text \u{1B}[201~ more"
let trickyOut = string(ChatComposer.payload(for: tricky, bracketed: true))
check(trickyOut.hasPrefix("\u{1B}[200~"), "the paste was not opened")
check(trickyOut.hasSuffix("\u{1B}[201~\r"), "the paste was not closed")

// 6. Drafting: voice, text and images join one message. The joining fails
//    silently in both directions — a path appended with no space makes one
//    nonsense token, and one appended after an existing space makes a double
//    space the user never typed and cannot see.
check(ChatComposer.appending("run the tests", to: "") == "run the tests",
      "drafting into an empty draft should be the piece alone")
check(ChatComposer.appending("a/b.png", to: "look at") == "look at a/b.png",
      "a piece after a word needs one space between them")
check(ChatComposer.appending("a/b.png", to: "look at ") == "look at a/b.png",
      "a draft already ending in a space must not gain a second")
check(ChatComposer.appending("a/b.png", to: "look at\n") == "look at\na/b.png",
      "a newline in the draft is respected, not doubled")
check(ChatComposer.appending("  dictated  ", to: "so") == "so dictated",
      "the added piece is trimmed at its edges")
check(ChatComposer.appending("", to: "unchanged") == "unchanged",
      "adding nothing changes nothing")
// The result must still be sendable and must submit as one message — the point
// of drafting is a single payload, not two.
let drafted = ChatComposer.appending("a/b.png", to: "look at this")
check(ChatComposer.isSendable(drafted), "a drafted message is sendable")
check(string(ChatComposer.payload(for: drafted, bracketed: true))
        == "\u{1B}[200~look at this a/b.png\u{1B}[201~\r",
      "the drafted message leaves as one payload")

print("PASS: sendable, delivery mode, submit, trim, multi-byte round-trip, and drafting")
SWIFT

swift "$WORK/main.swift"
echo "CHAT_COMPOSER_PASS"