# Parity audit against getmoshi.app

A fresh, adversarial pass over all 42 pages of getmoshi.app's documentation,
run 2026-10-09. Each doc page group was read by one agent that claimed gaps, and
every claimed gap was then handed to a separate agent whose only job was to
refute it by finding the implementation in this repo.

Result: **76 confirmed gaps, 30 claims refuted.** The raw findings — claim,
status, file:line evidence, and the verifier's reasoning — are in
`docs/parity-audit.json`.

This exists because the project's own PLAN.md had accumulated ✅ marks that a
second reader did not agree with. Several features marked done are, on
inspection, partly done or done differently, and that is worth recording
accurately rather than leaving in a table that reads as finished.

## What the statuses mean

- **missing** — no counterpart in the repo.
- **partial** — something related exists but does not do what the page
  promises.
- **deliberate-divergence** — deliberately not built, with the decision and its
  reason recorded somewhere in the repo. These are choices, not oversights, and
  are listed separately below.

## Where the gaps are

| Area | Confirmed gaps |
|---|---|
| Gestures | 11 |
| Hooks (agent support, settings, CLI) | 7 |
| Voice | 4 |
| Personalization (themes, fonts) | 4 |
| Diff viewer | 4 |
| Live Activity | 4 |
| Agents & Usages | 4 |
| Connections | 3 |
| Herdr | 3 |
| Keyboard | 3 |
| Chat View | 3 |
| Introduction, First session | 2 + 2 |
| Jump To, Clipboard, CJK input, Hook settings | 2 each |
| Apple Watch, Image paste, moshi CLI | 2 each |
| Multiplexer, Zellij, Security sync, Browser preview, Simulator preview, Files, Terminal sessions | 1 each |

## Structural gaps — a capability that needs a service this project does not run

These are not oversights and not fixable by writing app code. Moshi operates a
backend; this project deliberately does not.

- **Push notifications (APNs)** — the app and host code is complete and reaches
  the system boundary, but there is no `aps-environment` entitlement without a
  paid developer account, and Moshi's own route needs a hosted fan-out service.
- **Shareable HTTPS file URLs** — Moshi's Files surface is a pastebin: uploads
  return a short, expiring, host-independent HTTPS link, authenticated by the
  push token. Without that service there is nothing to serve the URL.
- **Cloud dictation quota** — Moshi's cloud engine is their hosted service with
  monthly quotas shown in settings. Here it is a user-supplied endpoint with no
  quota, because there is no service to quota.
- **Per-device push opt-out at the send side** — the gateway pushes to every
  registered device; the only opt-out is enforced on-device.

## Honest work still to do (not structural)

These are ordinary features that simply have not been built:

- Agent coverage: only Claude Code is wired; Moshi documents ~18 agents.
- `moshi-hook set` / `unset` / `uninstall` / `update` / `usage` / `version`
  subcommands, and any effect from `usage-collection` and `always-on-discovery`
  (both are parsed and then never read).
- Herdr prefix independent of tmux; Herdr pane-zoom on pinch.
- Chat View: Markdown/code/image rendering, approval bar, composer, mini-diffs.
- Diff viewer: side-by-side layout, syntax highlighting, commit browsing,
  remembering the open file, terminal-font reuse.
- Watch: grouping, usage complication, freshness.
- Voice: language picker, auto-send toggle.
- Command-history key, keyboard show/hide key (the latter now added).
- Windows host support (PowerShell/herdr.exe probe).
- Built-in Rosé Pine Dawn theme; the 570-theme gallery; bundled JetBrains Mono.

## Progress against this list

Being worked through after the audit. Each entry below was a confirmed gap that
has since been closed, with the check that pins it.

- **Enter / Backspace / keyboard-show-hide bar keys** — added to
  `InputSettings.Item`; `sendEnter` (CR) and `sendBackspace` (BS) are distinct
  from the existing `sendDelete` (DEL), which is the forward delete a terminal
  means by "Delete".
- **Custom-shortcut D-pad corners** — a fifth `CornerAction.custom` plus a
  stored shortcut string and a text field in Settings.
- **Gesture "Reset all"** — `GestureStore.resetAll`.
- **Push-to-talk dictation** — press-and-hold on the mic button, backed by a new
  `Dictation.start()` that does not toggle.
- **`usage-collection` and `always-on-discovery` did nothing** — both parsed
  from the config file and then never read. Wired to real behaviour.
- **Rosé Pine Dawn** — added to the built-in themes with the published palette,
  not an approximation from the background and accent.
- **OSC 52 read** — was stubbed to `nil`, so the remote could never read the
  clipboard. Now gated on an off-by-default Settings → Security switch. A
  biometric prompt per read would be better, but SwiftTerm's `clipboardRead` is
  synchronous with nowhere to await a Face ID sheet, so this is a deliberate,
  disclosed permission instead of a prompt that cannot exist.
- **Dictation language and auto-send** — a language picker (automatic or
  pinned) and a switch for submit-vs-review after dictating; both sync.
- **Keep screen on; hide the Code tab** — Settings → Agents. Neither syncs.

- **Host CLI subcommands** — `set` (read/write the `[gateway]` config, refusing
  unknown keys and normalising `on`/`off` to booleans), `usage` (fetches the
  gateway's `/usage`, since the event log is in the daemon's memory and a
  standalone computation would print an empty board), `version`, and
  `uninstall` (removes only the hooks this tool installed, matched by its own
  bridge path so hand-written hooks survive).
- **`usage-collection` / `always-on-discovery` actually do something now** —
  both gate their endpoint on a fresh config read.

Note on the last one: the config file is read once at daemon start, so
`cqutmux set` on a running gateway takes effect on the next start, not
immediately. Moshi's own hook-settings docs imply the same for its daemon.
