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

- **Two-finger swipes drive the multiplexer** — sideways moves pane, up and
  down moves tab (or opens herdr's workspace navigator, which is what Moshi
  documents because herdr ships no next-workspace key). Off in Settings →
  Input, where the two-finger drag falls back to the scrollback and the mouse
  wheel it always was. The commands are a table of the programs' own published
  defaults rather than grammar strings: `ShortcutGrammar` folds Shift away and
  appends a Return, and herdr binds `prefix+z` and `prefix+Shift+Z` to
  different things, so a chord built from that grammar would be a different
  binding than the one meant. Zellij gets `zellij action` lines, since it has no
  prefix — and gets no pane move at all, because its mode-entry key cannot be
  sent as one chord from the terminal and a stray `MoveFocus` would strand the
  user in zellij's pane mode.
- **A separate herdr prefix** under Settings → Multiplexer, with herdr's
  shortcut list shown beneath it. tmux and herdr are configured by different
  files and a host often runs both, so one shared prefix would rebind the other
  program's keys.
- **A pinch can zoom the pane** (Settings → Toolbar). Moshi's documented
  behaviour is that a pinch zooms the focused pane; here it has been the
  font-size control since before the setting existed, and it is the only way to
  resize text without leaving a session, so the font is still the default and
  the pane zoom is a choice. On a host with no multiplexer a pinch still resizes
  the text, so the gesture is never dead.

- **Recent directories discovered from the agents' own history** — a new
  `GET /recent-directories` on the gateway reads Claude Code's
  `~/.claude/projects/*/**.jsonl`, Codex's and OpenCode's session trees, and
  Cursor's, pulling a `cwd` out of the head of each transcript. The Claude Code
  *slug* is lossy (`/srv/a-b` and `/srv/a/b` both become `-srv-a-b`), so a path
  recovered from a directory name is marked `inferred` and shown with a
  question mark rather than presented as a fact. Settings → Code → Go to now
  lists them under "Agent history", separately from the app's own visits —
  those are two different claims and merging them would make a directory the
  user never opened look like one they had.
- **Header drags** — a short drag down on the status badge opens the session
  switcher; a long one, or a fast flick, minimizes: disconnect and pop back to
  the host list. The host's tmux/zellij/herdr session is untouched, which is
  what makes minimizing safe to offer as a gesture.

- **The Command History key** — a bar key and a More-menu entry that open the
  host's own shell history, read from `~/.zsh_history` / `~/.bash_history` by a
  new `GET /history`. Both record formats are handled, in the same file, since a
  shell can be upgraded under a history file: the extended `: <epoch>:<dur>;cmd`
  prefix is stripped by splitting on the *first* semicolon — a command may
  contain several — and a line ending in a backslash is joined back with a
  newline, because a `for` loop folded onto one line means something else. The
  key is opt-in rather than on the default bar: Moshi documents one default bar
  and adding a key to it on a guess would make that list no longer Moshi's.
  Unlike `/recent-directories` the route is *not* gated on
  `always_on_discovery` — that flag is about probing the host unasked, and this
  is the user asking. A tapped command is typed into the line editor and not
  run: it is one keystroke away from running something chosen from a list the
  host assembled, so it is left to be read first.

- **A private key can be imported from a file**, not only pasted. The picker
  accepts `~/.ssh/id_ed25519` and any other file (the private key is often
  extension-less), and the read happens inside the security-scoped window the
  URL is only valid for. The reader itself is now checked against keys
  `ssh-keygen` makes: the seed from the file must derive *exactly* the public
  key written beside it, because a reader that returned the wrong 32 bytes
  would still produce a plausible-looking key and only fail later as
  "permission denied (publickey)". An encrypted key is refused with a message
  saying why rather than imported as ciphertext.
- **Reset-all now clears both stores.** "Reset all gestures" cleared the
  gestures and left the custom keys, and the footer pointing at "their own
  screen" was pointing at a screen with no reset button. Each store now has a
  reset on the screen that lists what it clears.

- **A private key can be exported, behind biometrics.** Settings → Security →
  Exported keys holds the key list shut until a Face ID prompt passes — an
  unlocked phone in someone else's hand should not be enough to walk off with
  the key that reaches every host. The export is the app's own ed25519 seed
  re-emitted as an `openssh-key-v1` PEM, and it is deliberately *unencrypted*:
  the app holds a bare seed and has no passphrase to encrypt with, so the screen
  says so rather than implying the output is protected. Writing a PEM is the
  part that looks easy and is not — the check hands the exported file to
  `ssh-keygen -y` and compares the public key it derives, which caught a real
  bug: the outer public-key field takes the whole `ssh-ed25519` blob, not the 32
  raw bytes that go inside the private half, and writing the raw ones there
  yields a file ssh-keygen rejects as "invalid format" while this app's own
  reader reads it back perfectly happily.

- **Multi-agent install.** `cqutmux install` wired Claude Code alone. It now
  wires five, each in that agent's own documented format — and the formats
  really are different, which is why this is a table rather than one writer:
  Claude Code and Codex share the nested `PreToolUse`/`Stop` shape, Cursor uses
  camelCase events under `{version, hooks}`, Kimi Code CLI is a TOML `[[hooks]]`
  array with exactly four legal fields, and Antigravity keys its events under a
  *named* hook object. Codex additionally needs `features.hooks` set or it
  reads none of this, so the installer flips that flag and says why — a hooks
  file an agent silently ignores is the failure you cannot diagnose from the
  phone. OpenCode is deliberately left out: it documents no declarative command
  hook, only a JavaScript plugin API, and a config entry it would ignore is
  worse than no entry because it looks wired up.
- **Every agent's payload reaches one bridge.** The five agents hand a hook the
  same *kind* of JSON with differently-named fields (`tool_name` vs `toolName`,
  `session_id` vs `conversation_id`), so `agent-hook.mjs` reads whichever it was
  given and posts one event. Five per-agent bridge scripts would be five copies
  of the same curl and five chances to drift.
- **The hook token hole.** A gateway started with `--token` — which `install`
  tells you to do — refused every hook with a 401, and nothing surfaced it: the
  hooks looked installed and the inbox stayed empty, because the agent spawns
  the bridge with none of the gateway's environment. The gateway now publishes
  its token to `~/.cqutmux/token` (0600) while it runs and removes it on exit,
  and both bridges send it.
