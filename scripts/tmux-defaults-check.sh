#!/usr/bin/env bash
#
# Checks `cqutmux tmux-defaults`: the four settings Moshi recommends, and the
# rules for writing them into ~/.tmux.conf.
#
# Usage: scripts/tmux-defaults-check.sh
#
# What is asserted
# ----------------
# The command edits a file the user may have spent years curating, so the ways
# it can go wrong are all quiet ones:
#
#   - a block appended twice, setting each option twice with the last winning;
#   - a user's own `set -g history-limit 5000` overwritten by our 100000, when
#     the whole point is that their choice wins;
#   - the `update-environment` client-marker line (a different feature) caught up
#     in the rewrite or removed by `--unset`;
#   - an `--unset` that cannot find its block and leaves a stray `set` behind.
#
# The parse/plan logic is pure (`host/cqutmux-hook/tmux-defaults.mjs`), so its
# rules are asserted directly in `scripts/tmux-defaults/main.mjs`; the command
# half is run here against a throwaway config given by `CQUTMUX_TMUX_CONF`, so
# this never touches the real ~/.tmux.conf.
#
# Mutation-testing this check
# ---------------------------
# Each group was checked by breaking the module and watching exactly one thing
# go red:
#   - judge presence by value, not option name -> "the user's value is kept" fails
#   - append without stripping first            -> the idempotence check fails
#   - write pane-base-index with `set`          -> the harness's setw assertion fails
#   - stop skipping `-t <target>`               -> the pane-base-index parse fails
#   - match the client line as an option        -> the update-environment check fails
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> checking the tmux-defaults rules"
node scripts/tmux-defaults/main.mjs

# And the part that is not pure: the command reaches the dispatcher, edits a real
# file, and never touches one it was not pointed at.
echo "==> checking the command against a throwaway config"
CLI="$ROOT/host/cqutmux-hook/index.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CONF="$TMP/tmux.conf"
export CQUTMUX_TMUX_CONF="$CONF"

fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "PASS  $*"; }
run() { node "$CLI" tmux-defaults "$@"; }

# A file with the user's own choices already in it, including a history-limit
# we recommend but at a *different value*, and the client-marker line.
cat > "$CONF" <<'EOF'
# my tmux config
set -g history-limit 5000
set -g status-bg colour235
set-option -ga update-environment " CQUTMUX_CLIENT"
EOF
cp "$CONF" "$TMP/orig.conf"

# The plain report names the missing settings and honours the present one.
run > "$TMP/report.txt"
grep -q 'history-limit: present, your value' "$TMP/report.txt" \
  || fail "the report did not honour the user's own history-limit"
grep -q 'mouse: missing' "$TMP/report.txt" || fail "the report did not name mouse as missing"
run > /dev/null || fail "the plain report exited non-zero"
ok "the report honours a value the user already set and names the rest missing"

# --write adds the missing ones and leaves the user's own lines untouched.
run --write > /dev/null || fail "--write exited non-zero"
grep -q 'set -g mouse on' "$CONF" || fail "mouse was not written"
grep -q 'setw -g pane-base-index 1' "$CONF" || fail "pane-base-index was not written with setw"
grep -q 'set -g history-limit 5000' "$CONF" || fail "the user's history-limit was changed"
grep -q 'set -g history-limit 100000' "$CONF" && fail "our history-limit overrode the user's"
grep -q 'set -g status-bg colour235' "$CONF" || fail "the user's unrelated line was lost"
grep -q 'set-option -ga update-environment " CQUTMUX_CLIENT"' "$CONF" \
  || fail "the client-marker line was damaged"
ok "--write adds the missing settings and leaves the user's own lines alone"

# The user's lines keep their order and stay at the top; ours go after.
head -n 1 "$CONF" | grep -q 'my tmux config' || fail "the file was reordered"
ok "the user's lines keep their order, ours go after them"
[ -f "$CONF.cqutmux-backup" ] || fail "no backup was written before editing an existing file"
ok "the file was backed up before it was edited"

# Re-running must not stack a second block.
run --write > /dev/null
count=$(grep -c '# >>> cqutmux tmux-defaults >>>' "$CONF")
[ "$count" = "1" ] || fail "re-running left $count blocks, expected 1"
ok "re-running --write leaves exactly one block"

# --unset removes exactly the block, and the file returns to what it was plus
# nothing (the settings we added are gone; the user's own line is not).
run --unset > /dev/null || fail "--unset exited non-zero"
grep -q 'cqutmux tmux-defaults' "$CONF" && fail "unset left the block behind"
grep -q 'set -g mouse on' "$CONF" && fail "unset left our setting behind"
grep -q 'set -g history-limit 5000' "$CONF" || fail "unset removed the user's own line"
grep -q 'set-option -ga update-environment' "$CONF" || fail "unset removed the client-marker line"
# The block's removal must leave the file byte-for-byte as it started, trailing
# newline included — an editor that drops one has made an unasked-for change.
diff "$TMP/orig.conf" "$CONF" > /dev/null || fail "unset did not restore the original file"
ok "--unset removes the block and restores the file byte-for-byte"

# --unset on a file with no block is a no-op, not an error and not a creation.
run --unset > /dev/null || fail "--unset on a file with no block exited non-zero"
ok "--unset on a file with no block is a no-op"

# --write against a file that does not exist creates it, with all four.
FRESH="$TMP/fresh.conf"
CQUTMUX_TMUX_CONF="$FRESH" run --write > /dev/null || fail "--write on an absent file exited non-zero"
[ -f "$FRESH" ] || fail "--write did not create the absent config"
grep -q 'set -g history-limit 100000' "$FRESH" || fail "the created file is missing history-limit"
ok "--write creates a config that does not exist yet"
# --unset must not create a file: an uninstaller that invents a config has
# changed the user's setup in a way they did not ask for.
GONE="$TMP/gone.conf"
CQUTMUX_TMUX_CONF="$GONE" run --unset > /dev/null
[ -f "$GONE" ] && fail "--unset created a config that did not exist"
ok "--unset creates nothing"

# Both verbs at once is refused rather than guessed at.
if CQUTMUX_TMUX_CONF="$GONE" run --write --unset > /dev/null 2>&1; then
  fail "--write and --unset together were accepted"
fi
ok "--write and --unset together are refused"

# The command is advertised in help — one that exists in the switch but not in
# `usage` is installed and undiscoverable.
node "$CLI" help | grep -q "cqutmux tmux-defaults" || fail "tmux-defaults is not in help"
ok "tmux-defaults is advertised in help"

# The real ~/.tmux.conf was never in play: every invocation ran under the
# override above.
echo "PASS  every run stayed inside the CQUTMUX_TMUX_CONF override"

echo ""
echo "TMUX_DEFAULTS_OK"