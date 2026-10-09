#!/usr/bin/env bash
#
# Checks the diff viewer: per-file narrowing, path confinement, and the two
# one-shot CLI flags.
#
# Usage: scripts/diff-check.sh
#
# What is asserted
# ----------------
# 1. `GET /diff?file=` narrows the diff to that file *and* leaves the full file
#    list intact — the app needs the list to show what else changed, and a route
#    that narrowed the list too would make opening one file lose the review.
# 2. A `file=` that escapes the root is refused with 403, not passed to git. The
#    path arrives from the client, so this is the one route where a traversal
#    would read whatever on the host the user can.
# 3. `cqutmux set` prints the config path and its values, `--verbose` adds the
#    diagnostics on stderr only, and `--base-url` actually redirects the probe.
#
# Everything runs in a throwaway git repo, so the check never diffs the working
# tree of whoever runs it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATEWAY_PORT="${CQUTMUX_GATEWAY_PORT:-24661}"
TOKEN="diff-test"

WORK="$(mktemp -d)"
cleanup() { [[ -n "${GW_PID:-}" ]] && kill "$GW_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> building a throwaway repo"
cd "$WORK"
git init -q .
git config user.email "check@cqutmux.invalid"
git config user.name "CQUTmux check"
printf 'one\ntwo\nthree\n' > alpha.txt
mkdir -p nested
printf 'a\nb\n' > nested/beta.txt
git add -A && git commit -qm "base"
# Two modified files and one untracked, so the list has more than one entry and
# the narrowing has something to leave alone.
printf 'one\ntwo changed\nthree\n' > alpha.txt
printf 'a\nb\nc\n' > nested/beta.txt
printf 'new\n' > gamma.txt
cd "$ROOT"

echo "==> starting the gateway against the throwaway repo"
node host/cqutmux-hook/index.mjs --port "$GATEWAY_PORT" --token "$TOKEN" --root "$WORK" \
  >/tmp/cqutmux_diff_gw.log 2>&1 &
GW_PID=$!
sleep 2

echo "==> checking that file= narrows the diff without dropping the list"
GATEWAY_PORT="$GATEWAY_PORT" TOKEN="$TOKEN" python3 - <<'PY'
import json, os, urllib.request

port = os.environ["GATEWAY_PORT"]
token = os.environ["TOKEN"]


def get(path):
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", headers={"Authorization": f"Bearer {token}"}
    )
    try:
        return json.load(urllib.request.urlopen(request)), 200
    except urllib.error.HTTPError as error:
        return None, error.code


whole, status = get("/diff?path=.")
if status != 200:
    print(f"FAIL: /diff answered {status}")
    raise SystemExit(1)
if not whole["isRepo"]:
    print("FAIL: the throwaway repo was not detected as one")
    raise SystemExit(1)
paths = {f["path"] for f in whole["files"]}
for expected in ("alpha.txt", "nested/beta.txt", "gamma.txt"):
    if expected not in paths:
        print(f"FAIL: {expected} missing from the changed list: {sorted(paths)}")
        raise SystemExit(1)

one, status = get("/diff?path=.&file=alpha.txt")
if status != 200:
    print(f"FAIL: the narrowed diff answered {status}")
    raise SystemExit(1)
if "beta.txt" in one["diff"]:
    print("FAIL: the narrowed diff still carries another file's hunks")
    raise SystemExit(1)
if "two changed" not in one["diff"]:
    print(f"FAIL: the narrowed diff lost the file's own hunk: {one['diff'][:200]!r}")
    raise SystemExit(1)
# The list has to survive the narrowing: the app shows it beside the diff, and
# an empty one would make opening a file look like the tree had gone clean.
if {f["path"] for f in one["files"]} != paths:
    print("FAIL: narrowing the diff changed the changed-file list")
    raise SystemExit(1)

print(f"PASS: file= narrowed to alpha.txt and kept all {len(paths)} listed files")
PY

echo "==> checking that a path escaping the root is refused"
# The path comes from the client, so this is the one route where a traversal
# would read whatever on the host the user can. 403 rather than 404: the file
# may well exist, and saying so is the honest answer.
for escape in "../../../../etc/passwd" "/etc/passwd" "nested/../../../etc/passwd"; do
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' -G \
    -H "Authorization: Bearer $TOKEN" \
    --data-urlencode "path=." --data-urlencode "file=$escape" \
    "http://127.0.0.1:$GATEWAY_PORT/diff")"
  if [[ "$CODE" != "403" ]]; then
    echo "FAIL: file=$escape answered $CODE, expected 403"
    exit 1
  fi
done
echo "PASS: three traversal attempts were all refused with 403"

echo "==> checking the one-shot CLI flags"
cd "$ROOT"
SET_OUT="$(node host/cqutmux-hook/index.mjs set 2>/dev/null)"
echo "$SET_OUT" | head -1 | grep -q '/config.toml' \
  || { echo "FAIL: set did not print the config path: $SET_OUT"; exit 1; }
echo "$SET_OUT" | grep -q 'always_on_discovery' \
  || { echo "FAIL: set did not print the settings: $SET_OUT"; exit 1; }

# --verbose is diagnostics, so it must not pollute stdout: a script piping the
# settings through a parser would otherwise get a comment line it cannot read.
VERBOSE_ERR="$(node host/cqutmux-hook/index.mjs set --verbose 2>&1 >/dev/null)"
VERBOSE_OUT="$(node host/cqutmux-hook/index.mjs set --verbose 2>/dev/null)"
[[ "$VERBOSE_ERR" == *"setting(s)"* ]] \
  || { echo "FAIL: --verbose printed no diagnostic on stderr: $VERBOSE_ERR"; exit 1; }
[[ "$VERBOSE_OUT" != *"setting(s)"* ]] \
  || { echo "FAIL: --verbose leaked its diagnostics onto stdout"; exit 1; }
echo "PASS: set prints the path and settings, and --verbose stays on stderr"

# --base-url has to change where the probe goes, or it is decoration. Pointed at
# the live gateway it must succeed; pointed at a dead port it must not.
if ! node host/cqutmux-hook/index.mjs status --token "$TOKEN" --base-url "http://127.0.0.1:$GATEWAY_PORT" >/dev/null 2>&1; then
  echo "FAIL: status --base-url could not reach the gateway it was given"
  exit 1
fi
if node host/cqutmux-hook/index.mjs status --token "$TOKEN" --base-url "http://127.0.0.1:1" >/dev/null 2>&1; then
  echo "FAIL: status --base-url reported a gateway on a dead port"
  exit 1
fi
# `|| true`: `status` exits non-zero when nothing answered, which is the right
# behaviour and would otherwise trip `pipefail` before the assertion runs.
STATUS_JSON="$(node host/cqutmux-hook/index.mjs status --base-url http://127.0.0.1:1 --json 2>/dev/null || true)"
echo "$STATUS_JSON" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
if payload.get("url") != "http://127.0.0.1:1":
    print("FAIL: --json did not report the overridden url:", payload)
    raise SystemExit(1)
print("PASS: --base-url redirects the probe, and --json reports where it looked")
'

echo "DIFF_PASS"