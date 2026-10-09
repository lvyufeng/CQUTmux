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
- Chat View: Markdown/code/image rendering, approval bar, mini-diffs. (Composer now exists as Chat Mode — see the progress list.)
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

- **Ctrl double-tap locks it on**, so `^C ^C` or a shell's `^R` search is one
  gesture rather than one tap per key. Done by re-arming SwiftTerm's own
  `controlModifier` after each keystroke from both write paths — the bar's own
  and `insertText`, which is what a hardware or on-screen key goes through —
  rather than by translating keys here, which would be a second way of turning
  a key into a control character.
- **⌘K / ⌘O / ⌘N / ⌘W.** Two of these were bound and both were wrong: ⌘K cleared
  the screen and ⌘O toggled Ctrl. Clear screen moves to ⌘L, where a terminal
  normally puts it; ⌘K now opens the shortcut list, ⌘O the session switcher,
  ⌘N the host list, and ⌘W minimizes. The shortcuts reach the same sheets the
  accessory bar's buttons do, so the two cannot drift apart.
- **Long press on the keyboard button** opens Speech settings. The bar has no
  room for another key, and the keyboard button is the one that is about input,
  so that is where the dictation settings live from inside a session — without
  it, changing the engine means leaving the terminal you are dictating into.

- **A custom `mosh-server` path.** The launcher normally asks the host's login
  shell where the binary is, which handles a package manager or `~/.local` —
  and cannot handle a host where that shell cannot find it either (another
  user's install, a Nix profile, a container with no rc files setting PATH).
  The failure mode is the bad one: mosh silently becomes plain SSH, which looks
  like a preference being ignored. There is now a field on the connection form
  that skips the search.
- **The uploaded file's path goes on the host's clipboard.** Typing a path into
  an agent's prompt is not what you want when the target is a `vim` already open
  in a pane, so the upload route also puts the absolute path on the host's own
  clipboard through `pbcopy`, `wl-copy` or `xclip` — whichever is present, which
  is not knowable at startup. Best effort: a headless host has none, and the
  upload has already succeeded by then, so a missing tool must not fail it.
- **The Files panel can be hidden on its own.** Settings → Agents already hid
  the whole Code tab; this drops just the Files mode, for when the diff and the
  transcript are useful and browsing the host's tree is not.

- **Jump To's three layouts and the waiting count.** The screen had one flat
  list. Herdr's tree is the one thing here that can be *long* — every pane on
  the machine — and a flat list makes the pane you want a scroll rather than a
  glance. It now switches between List, Accordion (one workspace's panes shown,
  the rest folded to a header that still carries its counts and status) and Grid
  (mission-control cards, each workspace's panes as chips), and remembers the
  choice in `@AppStorage`, because someone who wants mission control wants it
  every launch. Above all three sits the aggregate "N waiting" banner, which is
  the reason to open this screen at all — it only appears when something is
  actually blocked, and its Show button drops straight into the grid. The
  per-row status dot is deliberately separate from the tinted agent glyph: the
  glyph says *what* runs in a pane, the dot says whether it needs you, and
  folding them into one mark leaves a blocked agent and an idle one differing
  only by hue — the exact distinction the screen exists to make. The
  `accordion`/`grid` layouts are reachable only through a toolbar menu, which a
  test script cannot open, so `scripts/jumpto-check.sh` starts the sheet in each
  layout via `CQUT_DEV_JUMPTO_LAYOUT` and checks the pixels against a live herdr
  server reporting a blocked pane.

- **A pinch that zooms the pane, and a custom-key lock.** The pinch has been
  the font-size control here since before there was a setting for it, so moving
  it outright would make the app feel like it had lost a control — both are now
  offered, with the font as the default and Moshi's documented behaviour a
  choice, in Settings → Toolbar *and* inline in the Gestures screen where the
  other terminal gestures live. The zoom goes through the host gateway's socket
  route rather than herdr's own `prefix z` chord, because the chord acts on
  whatever *herdr* thinks is focused, which is not necessarily the pane the
  phone is looking at; the socket API's default target is herdr's focused pane.
  The direction is explicit (`on` for pinch-out, `off` for pinch-back) so one
  gesture cannot mean two different things on alternate pinches.

  The custom keys gained a lock, and reading Moshi's docs properly moved it:
  their "shortcuts button" is the button that opens the shortcuts *panel*, not
  the accessory bar's Ctrl — which already has its own double-tap lock. So the
  head of the custom-key group now takes a single tap to open the editor and a
  double tap to stop the group sending to the terminal, with a single tap
  afterwards to bring it back. Deliberately not symmetric: demanding the double
  tap again to undo traps anyone who taps once and sees nothing happen. The
  lock does not survive a launch — a bar that comes back locked reads as a
  broken bar. `scripts/pinch-lock-check.sh` runs the real `ShortcutLock.swift`
  through the interpreter for the gesture logic and drives the zoom route
  against a live herdr, reading the result back from herdr's own layout rather
  than from the route's reply.

- **Per-file diffs, and a diff viewer that stays where you left it.** The
  Changes tab listed changed files but showed one flat diff of everything, in
  the system's monospaced stack. It now lists files (name over directory, the
  current one bookmarked) and opens each one's hunks on its own, narrowed on
  the host by `GET /diff?file=` rather than filtered on the phone — re-sending a
  whole working tree's diff to show one hunk is a megabyte of text the phone
  already has. Every diff and source view renders in the terminal's own font and
  line spacing, so the code you are reviewing is set in the same face as the
  code you are writing; a review that changes typeface is a review where
  alignment stops matching the terminal beside it. The remembered file and line
  are persisted, because a review is not one sitting.

  The check for this caught a real bug worth naming: `?file=/etc/passwd` was
  being re-rooted by `path.join` *before* the root-confinement check, so the
  check passed and git was handed a path outside the tree — answering 200 with
  an empty diff, which reads as a clean file rather than a refused request.
  Absolute and upward-escaping paths are now refused with 403, asserted for
  three traversal spellings. `scripts/diff-check.sh` also covers the two
  one-shot CLI flags Moshi documents: `--verbose`, whose diagnostics go to
  stderr so a script parsing the command's output is unaffected, and
  `--base-url`, a one-shot override of the loopback address for a gateway
  reached through an SSH port-forward, where the port is right and the host is
  not.

- **A gateway status dot per host, with five states.** The host list showed
  each saved host's name and target and nothing about whether it worked; health
  was only on the Support screen, which asks about the one host you have already
  connected to. The dot sits in the row and answers the case that screen cannot
  — the host that is *not* connected — by opening its own short-lived SSH
  connection and asking once. Five states rather than up/down because the three
  failures need different things done about them: running, an out-of-date
  gateway (something answers its port but not with a route this app knows),
  the wrong port (nothing where the host is set, a gateway on the default),
  installed-but-not-running, and not installed. Tapping the dot names the state
  and gives the one command that resolves it, selectable so it can be pasted
  onto the host.

  Checking this against a real host found two bugs worth naming. The probe
  script's `|| echo 000` appended to curl's own `000` for a refused connection,
  producing `000000` — which is not `"000"`, so every dead port read as
  *answering* and every host showed a green dot: the one thing the screen exists
  to catch was the one thing it hid. And the interpreter now accepts only a
  three-digit 100–599 status, so no garbled value can read as a live gateway.
  The screen's own claim is that a wrong fix is worse than no answer, so the
  interpreter was moved into a file that imports only Foundation and is run
  directly by `scripts/gateway-status-check.sh`, rather than only through a
  simulator. The fixes it offers were also checked against what this repo can
  actually be installed from — there is no npm package, so "npm i -g" would have
  been a command that is followed and then believed when it does nothing.

- **Settings → Hooks: the Live Activity preference, the tap destination, and a
  test.** The Live Activity was unconditional: it appeared whenever the poll saw
  a pending approval and vanished when it did not, with no way to say no and no
  way to tell whether it worked without waiting for a real approval. There is now
  a Hooks screen with two switches and a test button. Both default to *on*, and
  that is the part worth stating: the defaults are read through
  `object(forKey:)` rather than `bool(forKey:)`, because the latter cannot tell
  "never set" from "set to false" — with it, a device that had never opened this
  screen would show the feature already off.

  What the activity *shows* was also moved out of `ActivityManager` into
  `AgentActivityPreview`, a Foundation-only file, so the test button drives the
  same decision the Inbox does. A test that built its own state would render
  something the real path never produces and prove nothing. The decision covers
  three cases the old code got wrong or did not have: a pending approval counts
  (with the plural derived, not hardcoded), a resolved approval lingers at zero
  rather than blinking out mid-answer, and a bare notice produces *no* activity
  at all — badging the Lock Screen for agent chatter claims the user is needed
  when nothing is waiting.

  "Open Inbox on tap" is enforced in the app rather than in the widget: the
  widget extension has its own `UserDefaults` container and no app group, so
  reading the setting there would always answer with the default and the toggle
  would change nothing. The widget still carries the `cqutmux://inbox` URL, and
  `RootView.handleInbox` decides whether to act on it.

  Checking this on a simulator found a real bug that the old code had hidden.
  `Activity.request` throws "Target does not include NSSupportsLiveActivities
  plist key" when the app's Info.plist lacks that key, and the app had no such
  key. The request was wrapped in `try?`, so the failure produced no activity, no
  error and no log — the Live Activity had never once run, while the code, the
  widget and the docs all read as if it had. Fixed by adding
  `NSSupportsLiveActivities` to `project.yml` (XcodeGen writes App/Info.plist
  from it, so a hand edit to the plist would be reverted), and by returning an
  `ActivityManager.Outcome` instead of swallowing the throw, so the test button
  can say *why* nothing appeared. `scripts/hooks-activity-check.sh` pins the
  defaults, the decision, the sample timestamps, the plist key, and the absence
  of the `try?`.

- **Chat mode — a composer outside the TUI.** Gaps 2 and 37 are the same missing
  feature seen from two directions: the docs describe a chat mode that composes a
  prompt before sending (rather than typing straight into the shell), and name it
  again as the fallback when a full-screen TUI disrupts CJK composition. Neither
  existed; the Chat surface was a read-only transcript reader.

  The reason the terminal cannot serve this is worth stating, because "just add a
  text field" would miss it. Command mode types *into* the terminal through
  SwiftTerm's `UITextInput`, which lives inside the TUI — and a TUI that repaints
  over the marked range breaks iOS keyboard composition, so Chinese and Japanese
  marked text and candidate selection can land in the wrong place, in the wrong
  order, or not at all. The composer is a real `TextField` outside the terminal,
  in a view no agent can repaint, and its finished string is delivered in one
  piece.

  Delivery is what makes it chat mode rather than a slower keyboard: when the
  program on the other end has turned on bracketed paste, the message is wrapped
  in `ESC[200~ … ESC[201~` so it arrives as *one paste* rather than as typing,
  which is what makes a TUI insert it as text instead of interpreting keystrokes.
  The mode bit comes from the terminal's own `bracketedPasteMode` — the same bit
  SwiftTerm reads for a real paste — so the markers and their absence cannot
  drift from what the other end expects. When bracketed paste is off (a plain
  shell) the markers are not sent, because a shell that never negotiated them
  prints them as literal garbage. A trailing CR always follows, which is the
  difference from command mode: the message is submitted, not left in the input.

  `ChatComposer` is Foundation-only and run directly by
  `scripts/chat-composer-check.sh`, which pins the cases that fail invisibly:
  whitespace-only input sends nothing (an empty Enter would fire an empty turn),
  the CR stays outside the paste (a CR inside it is an inserted newline, not a
  submit), edges are trimmed while interior newlines are kept, and a CJK message
  survives byte-for-byte inside the markers. Verified end to end on the simulator
  against a real sshd: `CQUT_DEV_COMPOSE` drives the view's own `sendComposed`
  and the host runs the command, and `CQUT_DEV_CHAT_MODE=1` screenshots the
  composer in place of the key bar.
