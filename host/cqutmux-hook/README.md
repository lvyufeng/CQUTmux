# cqutmux-hook

Host-side gateway for CQUTmux. Agent hooks report events here; the iOS app
reads them back over the SSH session it already has.

```
node index.mjs [--port 24543] [--token <secret>]
```

No dependencies, Node 18+.

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

Event body:

```json
{ "source": "claude-code", "kind": "approval", "title": "Write to /etc/hosts",
  "body": "Edit needs sudo", "data": { "tool": "Edit" } }
```

`kind` is `approval` (needs a decision) or `notice` (informational).

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