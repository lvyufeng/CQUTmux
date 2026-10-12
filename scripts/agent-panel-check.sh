#!/usr/bin/env bash
#
# Checks the agent command panel's model layer without a simulator.
#
# The panel is a table of buttons an agent session is handed: a bad entry — a
# button that sends the wrong bytes, a duplicated id that makes SwiftUI's
# `ForEach` drop a row, an off-by-one in the reorder logic — is indistinguishable
# from a working one until the user presses it in a live session. None of it
# logs and none of it errors. So the defaults, the source detection, and the
# store's edit/persist round trip are asserted here, straight from the app
# target's pure files.
#
# `AgentPanel.swift` uses `@Observable`, but that is fine for a plain `swiftc`
# build: the macro ships with the Observation module in the toolchain, so no
# separate binary or plugin pass is needed. It imports Foundation + Observation
# only, which is the whole reason it can be compiled apart from the view.
#
# `AgentPanelBar.swift` is *not* compilable on its own — it is `import SwiftUI`
# and uses iOS-only members (`navigationBarTitleDisplayMode`,
# `textInputAutocapitalization`), which `swiftc` on macOS rejects. But the three
# helpers this file most needs to check (`AgentPanelPages.detect`,
# `controlButtons`, `muxButtons`) and the `PanelButton` they return are pure
# Foundation: the first ~139 lines of the file, up to the closing brace of
# `AgentPanelPages`, contain no SwiftUI at all (the `import SwiftUI` on line 1
# is the only mention, and it is the same module `Foundation` re-exports the
# types from). So the slice is extracted *from the real source* on each run —
# never a copy — and its `import SwiftUI` swapped for `import Foundation`. If a
# future edit moves a SwiftUI dependency into those lines, the extraction stops
# compiling and this check fails, which is the honest outcome: the helpers can
# no longer be checked apart from the view.
#
# Usage: scripts/agent-panel-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# The pure slice: everything up to and including the closing brace of
# `AgentPanelPages`, with the SwiftUI import swapped for Foundation.
awk '
  /^enum AgentPanelPages \{/ { inenum = 1 }
  { print }
  inenum {
    o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
    depth += o - c
    if (depth == 0) exit
  }
' "$ROOT/App/Features/Terminal/AgentPanelBar.swift" \
  | sed '1s/^import SwiftUI$/import Foundation/' \
  > "$OUT/AgentPanelPure.swift"

if ! head -1 "$OUT/AgentPanelPure.swift" | grep -q '^import Foundation$'; then
  echo "FAIL  could not extract the pure slice of AgentPanelBar.swift"
  exit 1
fi

swiftc -O -o "$OUT/check" \
  "$ROOT/App/Features/Terminal/AgentPanel.swift" \
  "$ROOT/App/Features/Terminal/ShortcutGrammar.swift" \
  "$ROOT/App/Features/Terminal/MuxSettings.swift" \
  "$OUT/AgentPanelPure.swift" \
  "$ROOT/scripts/agent-panel/main.swift"

"$OUT/check" | tee "$OUT/results"

if grep -q '^FAIL' "$OUT/results"; then
  exit 1
fi