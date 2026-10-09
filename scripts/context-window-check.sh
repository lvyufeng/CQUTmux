#!/usr/bin/env bash
#
# Checks the context-window reading the Inbox ring draws.
#
# Usage: scripts/context-window-check.sh
#
# What is asserted
# ----------------
# 1. Tokens are the *distinct* parts of the newest turn, not a sum across
#    turns. Input tokens are re-sent every turn, so summing them counts the
#    same window once per message and shows a healthy session as permanently
#    full — the failure that makes a ring useless while looking plausible.
# 2. The newest turn that carries a reading wins, and a turn reporting only
#    zeros is not a reading: an agent mid-compaction would otherwise draw the
#    ring at 0% and claim the context was empty.
# 3. The fraction clamps to 0…1, so a measurement over the limit reads as full
#    rather than as a ring past its own end.
# 4. The warning band is the same 0.85 the watch complication uses, so the two
#    surfaces never disagree about "nearly full".
# 5. A limit of zero (or negative) yields no reading rather than a division by
#    zero.
#
# `ContextWindow.swift` imports only Foundation, so it is run here directly
# through the Swift interpreter, together with the two types it reads.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PURE_FILES=(
  App/Shared/ISODate.swift
  App/Features/Agents/ChatTranscript.swift
  App/Features/Agents/ContextWindow.swift
)

for file in "${PURE_FILES[@]}"; do
  if grep -qE '^import ' "$file" | grep -qv '^import Foundation$'; then
    echo "FAIL: $file imports something beyond Foundation:"
    grep -E '^import ' "$file" | grep -v '^import Foundation$'
    exit 1
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> checking the context-window reading"
for file in "${PURE_FILES[@]}"; do
  cat "$file" >> "$WORK/main.swift"
  printf '\n' >> "$WORK/main.swift"
done
cat >> "$WORK/main.swift" <<'SWIFT'

func check(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: \(message)")
        exit(1)
    }
}

/// An assistant message carrying a usage block.
func turn(_ usage: [String: Int]) -> AgentMessage {
    AgentMessage(id: UUID().uuidString, role: .assistant, at: nil,
                 blocks: [], model: "claude", usage: usage)
}

/// A message with no usage at all — a user turn or a tool result.
func plain(_ role: AgentMessage.Role) -> AgentMessage {
    AgentMessage(id: UUID().uuidString, role: role, at: nil, blocks: [], model: nil, usage: nil)
}

// 1. Distinct parts of one turn, not a cross-turn sum. This is the whole point
//    of the type: 100 sent twice is one window of 100, not two of 200.
let oneWindow = ContextWindow.usage(
    from: [turn(["input_tokens": 60, "cache_read_input_tokens": 30,
                 "cache_creation_input_tokens": 10, "output_tokens": 5])],
    limit: 200
)
check(oneWindow?.tokens == 105, "one turn's tokens were \(oneWindow?.tokens ?? -1), expected 105")

let twoTurns = ContextWindow.usage(
    from: [turn(["input_tokens": 100]), turn(["input_tokens": 100])],
    limit: 200
)
check(twoTurns?.tokens == 100,
      "two turns summed to \(twoTurns?.tokens ?? -1) — input tokens are re-sent, not additive")

// Cached and uncached input are disjoint in the protocol and must all count.
let cached = ContextWindow.usage(
    from: [turn(["input_tokens": 10, "cache_read_input_tokens": 190, "cache_creation_input_tokens": 5])],
    limit: 1000
)
check(cached?.tokens == 205, "cache tokens were missed: \(cached?.tokens ?? -1)")

// 2. The newest reading wins even when it is smaller — an agent that just
//    compacted is genuinely using less.
let newest = ContextWindow.usage(
    from: [turn(["input_tokens": 5000]), plain(.user), turn(["input_tokens": 1000])],
    limit: 20000
)
check(newest?.tokens == 1000, "the newest turn did not win: \(newest?.tokens ?? -1)")

// A zeros-only reading is skipped, not reported as 0% full. There is an earlier
// real reading to fall back to.
let zeros = ContextWindow.usage(
    from: [turn(["input_tokens": 800]), turn(["input_tokens": 0, "cache_read_input_tokens": 0])],
    limit: 1000
)
check(zeros?.tokens == 800, "a zeros-only turn was treated as a reading: \(zeros?.tokens ?? -1)")

// All zeros, no fallback: nothing to report rather than 0%.
check(ContextWindow.usage(from: [turn(["input_tokens": 0])], limit: 1000) == nil,
      "an all-zero usage produced a reading")
check(ContextWindow.usage(from: [plain(.assistant), plain(.tool)], limit: 1000) == nil,
      "messages with no usage produced a reading")

// 3. Clamping. Over the limit reads as full, not as a ring past its end.
let over = ContextWindow.usage(from: [turn(["input_tokens": 1000])], limit: 500)
check(over?.fraction == 1, "an over-limit reading was \(over?.fraction ?? -1), expected 1")
check(over?.remaining == 0, "an over-limit reading reported \(over?.remaining ?? -1) remaining")

// 4. The warning band is exactly the shared constant, and it is the same number
//    the watch complication uses.
check(ContextWindow.Usage.warningFraction == 0.85,
      "the warning band changed: \(ContextWindow.Usage.warningFraction)")
let justUnder = ContextWindow.Usage(tokens: 84, limit: 100)
let atBand = ContextWindow.Usage(tokens: 85, limit: 100)
check(!justUnder.isWarning, "84% was flagged as a warning")
check(atBand.isWarning, "85% was not flagged as a warning")

// The remaining count is what is left, computed from the same two numbers.
check(ContextWindow.Usage(tokens: 30, limit: 200).remaining == 170,
      "remaining was not limit minus tokens")

// 5. A zero limit is no reading, not a division by zero.
check(ContextWindow.Usage(tokens: 100, limit: 0).fraction == 0,
      "a zero limit produced a non-zero fraction")

// And the default the settings screen assumes is the documented one.
check(ContextWindow.defaultLimit == 200_000,
      "the assumed window changed: \(ContextWindow.defaultLimit)")

print("PASS: distinct tokens, newest reading, clamping, warning band, zero limit")
SWIFT

swift "$WORK/main.swift"
echo "CONTEXT_WINDOW_PASS"