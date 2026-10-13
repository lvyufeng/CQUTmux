#!/usr/bin/env bash
#
# Checks the unified-diff line classifier the chat's diff sheet tints with.
#
# The classification fails silently in both directions and neither shows up in
# a screenshot as a wrong colour: the `---`/`+++` file headers paint red and
# green (they are spelled like a removed and an added line), and a hunk line
# that happens to be spelled like a header — the file's own content — paints
# like metadata. Only knowing whether the line sits inside a hunk tells them
# apart, so this runs whole diffs, not single lines. Foundation-only, so this
# needs no simulator.
#
# The second half checks the wiring, from the view source, because a correct
# classifier that nothing calls is the same screenshot as no classifier. The
# tint switch is exhaustive with no `default:` on purpose: a new kind must be a
# build error, not a silent fallback colour.
#
# Usage: scripts/diffline-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/App/Features/Code/DiffLineKind.swift"
VIEW="$ROOT/App/Features/Agents/ChatView.swift"

# The classifier is compiled on its own below, so an import it does not need is
# a broken check rather than a broken app, and the message here says which.
if grep -E '^import ' "$CLASSIFIER" | grep -qv '^import Foundation$'; then
  echo "FAIL: $CLASSIFIER imports something beyond Foundation:"
  grep -E '^import ' "$CLASSIFIER" | grep -v '^import Foundation$'
  echo "DIFFLINE_FAIL"
  exit 1
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/check" \
  "$CLASSIFIER" \
  "$ROOT/scripts/diffline/main.swift" 2>&1 | grep -v "^ *$" || true

[[ -x "$OUT/check" ]] || { echo "DIFFLINE_BUILD_FAIL"; exit 1; }

# Keep the helper's own count so the summary line carries one total.
if ! "$OUT/check" > "$OUT/out"; then
  cat "$OUT/out"
  echo "DIFFLINE_FAIL"
  exit 1
fi
# The helper's own summary is dropped: this script prints one `_PASS` line, and
# two of them would make the runner's "last one wins" a coincidence.
grep -v 'DIFFLINE_PASS' "$OUT/out" || true
unit="$(sed -n 's/.*(\([0-9]*\) checks).*/\1/p' "$OUT/out" | tail -1)"
[[ -n "$unit" ]] || { echo "DIFFLINE_FAIL"; exit 1; }

echo
echo "==> the sheet tints through the classifier"

wiring=0
fail=0
check() { # <condition: 1|0> <label>
  wiring=$((wiring + 1))
  if [ "$1" = "1" ]; then
    printf '  ok    %s\n' "$2"
  else
    printf '  FAIL  %s\n' "$2"
    fail=$((fail + 1))
  fi
}

check "$(grep -qF 'DiffLineKind.lines(in:' "$VIEW" && echo 1 || echo 0)" \
  "the sheet classifies its diff with the checked classifier"

# The exact call the tint replaced. A diff that is one `Text` again has no
# per-line colour and no per-line kind, which is what this check exists for.
check "$(grep -qF 'Text(changed.diff)' "$VIEW" && echo 0 || echo 1)" \
  "the sheet does not draw the diff as one unclassified blob"

# A `default:` here would take every future kind and paint it a colour nobody
# chose, and the build would stay green. The body runs to the function's own
# closing brace at four spaces — the switch's own `}` is indented deeper.
tint_body="$(awk '/private func tint\(/ { inside = 1 } inside && /^    }/ { exit } inside { print }' "$VIEW")"
defaults="$(printf '%s\n' "$tint_body" | grep -c 'default:' || true)"
check "$([ "$defaults" -eq 0 ] && echo 1 || echo 0)" \
  "the tint switch has no default:, so a new kind is a build error"

check "$(printf '%s\n' "$tint_body" | grep -q 'case .added' && echo 1 || echo 0)" \
  "the tint switch maps the kinds it is given"

if [ "$fail" -ne 0 ]; then
  echo "DIFFLINE_FAIL"
  exit 1
fi

echo "DIFFLINE_PASS  ($((unit + wiring)) checks)"