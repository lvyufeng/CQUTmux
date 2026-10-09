# cqutmux-hook

Host-side gateway for CQUTmux. Agent hooks report events here; the iOS app
reads them back over the SSH session it already has.

```
node index.mjs [--port 24543] [--token <secret>] [--root <dir>] [--webhook <url>]
```

No dependencies, Node 18+.

## Command line

The same file answers to `cqutmux` and `cqutmux-hook`, as Moshi ships `moshi`
alongside `moshi-hook`. With no subcommand it behaves exactly as before — it
starts the gateway — because that is what already-running installs expect.

```
cqutmux <dir>       open (or attach to) a tmux session named after the directory
cqutmux diff        summarise the current repo's diff (the app's Diff view reads /diff)
cqutmux status      is a gateway running here, and what does it say
cqutmux doctor      check tmux, git, ssh, the gateway and the token, in that order
cqutmux logs [-f]   tail ~/.cqutmux/hook.log
cqutmux serve       run the gateway, spelled out
cqutmux install     write agent hooks + how to keep the gateway running
cqutmux pair        host, address, port and token — what to enter in the app
cqutmux help
```

A single argument is a **path**, not a subcommand, so `cqutmux ~/src/api` names
a project rather than being read as a typo'd command. `scripts/cli-check.sh`
covers this file's behaviour, including the one thing that must not change:
that a bare invocation still starts the gateway.

### What `install` writes

`cqutmux install` adds our hook to `~/.claude/settings.json` for you, rather
than leaving you to edit it by hand. The rules it follows:

- **Your hooks are kept.** Ours are recognised by the bridge script's path, so
  anything already in the file — other hooks, unrelated settings — survives.
- **Re-running updates, it does not stack.** Run it twice and the file is the
  same as after one run.
- **It backs up first.** The original is copied to
  `~/.claude/settings.json.cqutmux-backup` on the first write.
- **A file it cannot parse is left alone.** If the JSON is invalid, it says so
  and exits non-zero rather than rewriting something it does not understand.
- **`--dry-run` prints what it would write** and touches nothing.

Pass `CQUTMUX_PORT` to the bridge if the gateway is not on 24543; `install`
writes the script path, which reads the port from the environment at run time.

`--webhook` posts a small JSON alert to an external endpoint (Slack, ntfy, a
phone Shortcut…) whenever an `approval` event arrives. Delivery is
fire-and-forget with a 5s timeout; a failing webhook never blocks or crashes
the gateway. `CQUTMUX_WEBHOOK` sets the same thing.

## Why loopback

The listener binds to `127.0.0.1` only. The phone reaches it through the SSH
connection (`direct-tcpip` port forwarding), so the gateway is never exposed to
the network — matching Moshi's "no session relay" design. Set `--token` to
require `Authorization: Bearer <secret>` on every request.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | liveness, event count, pending approvals |
| `GET` | `/events?since=<id>&wait=1` | events after `<id>`; `wait=1` long-polls up to 25s |
| `POST` | `/events` | append an event |
| `POST` | `/approve/<id>` | resolve a pending approval |
| `GET` | `/files?path=<dir>` | list a directory under `--root` |
| `GET` | `/file?path=<file>` | read a text file under `--root` |
| `GET` | `/diff?path=<dir>` | `git diff` + `git status` for a repo |
| `GET` | `/log?path=<dir>&limit=<n>` | recent commits (hash, author, subject, refs) |
| `GET` | `/usage` | 5h / 7d burn windows per agent |
| `GET` | `/sessions` | tmux and zellij sessions, windows/tabs and pane counts |
| `GET` | `/ports` | listening TCP ports, dev-looking ones first |
| `GET` | `/simulators` | booted iOS simulators on the host |
| `GET` | `/simulator/screenshot?udid=<id>` | a PNG frame of one booted simulator |
| `GET` | `/herdr` | herdr workspaces, tabs and panes (needs `--herdr <path>`) |
| `GET` | `/uploads` | pasted files, newest first |
| `GET` | `/upload?name=<n>` | one pasted file's bytes |
| `DELETE` | `/upload?name=<n>` | remove a pasted file |

## Containers

The gateway expects to share the host's tmux, git and simulator state, so it is
meant to run on the host itself. If you run it inside a container, mount the
project directories and the tmux socket (`/tmp/tmux-$(id -u)`) through, and
start it with `serve` so it does not try to be a project launcher:
`docker run -v /tmp/tmux-$(id -u):/tmp/tmux-1000 <image> serve`. Running it in a
container with a private tmux server is the one arrangement that will not work:
the app would attach to an empty session list.
| `POST` | `/upload` | write a raw body (a pasted image) under `.cqutmux/paste/` |

Event body:

```json
{ "source": "claude-code", "kind": "approval", "title": "Write to /etc/hosts",
  "body": "Edit needs sudo", "data": { "tool": "Edit" } }
```

`kind` is `approval` (needs a decision) or `notice` (informational).

`POST /upload` takes the file as the raw request body (not JSON or multipart)
and the name in an `X-Filename` header; the reply is
`{ "path": "/home/you/.cqutmux/paste/…" }`, which the app types into the
agent's prompt:

## Wiring an agent

Point a Claude Code hook (or any agent that can run a command on a tool event)
at `POST /events`. Example for a PreToolUse hook:

```sh
curl -s -X POST http://127.0.0.1:24543/events \
  -H 'content-type: application/json' \
  -d "{\"source\":\"claude-code\",\"kind\":\"approval\",\"title\":\"$TOOL_NAME\",
       \"body\":\"$TOOL_INPUT\"}"
```

## Test

```sh
node index.mjs --port 24543 &
curl -s localhost:24543/health
curl -s -X POST localhost:24543/events -d '{"title":"hello"}'
curl -s localhost:24543/events
```