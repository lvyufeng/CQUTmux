# Parity audit against getmoshi.app

A fresh, adversarial pass over all 42 pages of getmoshi.app's documentation,
run 2026-10-09. Each doc page group was read by one agent that claimed gaps, and
every claimed gap was then handed to a separate agent whose only job was to
refute it by finding the implementation in this repo.

Result: **76 confirmed gaps, 30 claims refuted.** The raw findings — claim,
status, file:line evidence, and the verifier's reasoning — are in
`docs/parity-audit.json`.

## Status as of 2026-10-10

Re-verified a second time, one agent per open gap, each told to judge the claim
against the working tree rather than trust this file — because this file has
been wrong before. Three earlier notes (the two-finger multiplexer sweeps,
Herdr's separate prefix, the Zellij tab row) described features as missing when
they were already implemented and the note had simply gone stale.

That pass moved **6 more entries to closed** (the pinch-to-zoom option, OSC 52
read, the Chat View composer, six `cqutmux-hook` subcommands, the
`always-on-discovery` and `usage-collection` toggles), confirmed the single
`missing` entry as genuinely absent, and rewrote the evidence on every entry
that is still open.

**Since then, more closed** — "Read first" on a pending approval; the Watch
inbox's project grouping plus its toolbar fill; the host-locale claim, both
halves (LANG and LC_ALL cross, and `cqutmux locale` now writes the guarded
block into ~/.zshenv and ~/.bashrc so a spawned shell inherits it); the per-agent Usages
windows; the browser-preview listener metadata; and `cqutmux diff`'s browser
viewer, which closes a deliberate divergence, and the `cqutmux context` probe.
Most recently the Inbox's five categories, which also turned up a gateway that
was dropping the field the bridges were already sending; the Live Activity's
latest-event and session-lifecycle phases; the Chat View's Markdown/code/image
separation; the tool cards' shape recognition; the Chat View's terminal entry
and its derived header; the host-locale rc injection that finishes the
locale claim; resuming the last session on relaunch; and the session
picker's Recent tab, which returns to a folder rather than a session; and
the code viewers' treatment of a font collection, which the terminal
renders and the diff viewer does not.
See the progress list below.
The "Read first" change also had an adversarial pass that refuted two claims it
first shipped with, both folded into the fix.

| Status | Count |
|---|---|
| closed | 69 |
| partial | 5 |
| deliberate-divergence | 1 |
| missing | 1 |

(The machine-readable `counters` field in `parity-audit.json` had drifted three
entries behind the per-entry statuses; this pass recomputes it from the entries
themselves, so the table above and that field now agree.)

**Read the numbers with care.** "Closed" means a counterpart exists and was
traced end to end by a reader that was trying to refute it. It does not mean
every path is exercised on a real device: several entries carry an explicit
limit in their `verification` field (a widget's placement on a face cannot be
observed headlessly; the simulator drops App Group entitlements; the tab row's
button press was verified by bytes on the wire rather than by a tap). Those
limits are recorded per entry rather than averaged away here.

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
- Watch: freshness (the context ring now feeds the data the complication would show; grouping and the usage complication are done).
- Voice: language picker, auto-send toggle.
- Command-history key, keyboard show/hide key (the latter now added).
- Windows host support (PowerShell/herdr.exe probe).
- Built-in Rosé Pine Dawn theme; the 570-theme gallery; bundled JetBrains Mono.

## Progress against this list

Being worked through after the audit. Each entry below was a confirmed gap that
has since been closed, with the check that pins it.

- **"Read first" on a pending approval** — the pending event's body is now
  drawn on the row (`AgentEvent.promptText` / `promptClampLines` /
  `promptOffersReading`, `InboxView.SessionRow`), clamped to four lines with a
  Read first / Show less toggle, and the same reading goes to the Watch with the
  same clamp and an expand. Two things this got wrong before it was right, both
  invisible on a screen: the body the hook sends is `json.dumps(tool_input)`, so
  a multi-line command arrives as one physical line with `\\n` escaped — shown
  verbatim the row was braces and backslashes, and the four-line clamp never
  fired; and the clamp counted lines while the button counted characters, so a
  body could be folded away with no way to open it. `promptText` renders the
  command (the same reading `AgentBlock.toolSummary` already gives the Chat
  view) and the toggle is gated on the clamp's own line count. Pinned by
  `scripts/inbox-check.sh` (79 checks), including a fixture in the exact shape
  the hook puts on the wire. The two sibling surfaces that announce a pending
  approval — the Live Activity and the push notification text — still show the
  title alone and are tracked separately.

- **The Add-attachment sheet** — clipboard-only before; now offers Camera, Photo Library, Files and
  Clipboard, all feeding the existing annotate/upload path. The photo library uses `PHPickerViewController`
  on purpose: it runs out of process and needs no photo-library permission, so picking a single image does
  not add a permission prompt. The camera is the one path that needs `NSCameraUsageDescription`, whose
  string was widened from the QR scanner to cover it.
  The rule that fails silently is *which rows appear* — a Clipboard row with nothing on the clipboard
  opens onto "No image on the clipboard" and reads as a broken button — so it is a Foundation-only
  function, `AttachmentSource.available`, pinned by `scripts/attachment-check.sh` (14 checks). A screenshot
  shows the rows that were drawn, never the one that should have been.

- **Multi-step shortcut timing** — `ShortcutGrammar.Parsed.schedule` gives each step the delay before
  it (the first at zero), `interStepDelay` is the gap, and `CQUTTerminalView.send(_:)` writes them as
  one main-actor task. A single keystroke keeps the old immediate path (`needsPacing`), so nothing about
  an ordinary key got slower. The failure this fixes is invisible to a byte check: a tmux chord sent as
  one write arrives in a single read and lands only by luck, and a delay placed *before* the first byte
  would make every key feel late — which is why the schedule distinguishes the two, and why the check
  (`scripts/shortcut-grammar`, a new "multi-step pacing" block) asserts the shape of the timing rather
  than just the bytes.

- **Enter / Backspace / keyboard-show-hide bar keys** — added to
  `InputSettings.Item`; `sendEnter` (CR) and `sendBackspace` (BS) are distinct
  from the existing `sendDelete` (DEL), which is the forward delete a terminal
  means by "Delete". The keyboard half needed two keys rather than one: the
  first release only had the dismiss button, and nothing else in the terminal
  can raise the keyboard — a tap on the pane goes to a gesture recogniser before
  the responder ever sees it — so pressing it was one-way for the rest of the
  session. A separate `Show keyboard` key calls `showKeyboard()`, which is
  `reloadInputViews()` on the view that is *already* first responder (calling
  `becomeFirstResponder` alone would be a no-op there). Both are off by default
  and listed in `optInItems`, since Moshi's default bar has one documented
  shape. `scripts/input-check.sh` (93 checks) pins the item, its label and the
  reachability invariant; the button's own behaviour is not asserted on screen —
  the bar's position moves with the keyboard's frame, so a coordinate tap aimed
  at it misses, and the check says so rather than guessing a pixel.
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

- **The Inbox context-window ring.** Each row now carries a small ring and a
  percentage showing how full the agent's context window is. The number is not
  in the events the gateway emits — those carry no token counts — so it is read
  from the agent's own transcript log, the same log the Chat view reads.

  The arithmetic is the part worth getting right, and it lives in a
  Foundation-only `ContextWindow` for that reason. The window is the **last**
  turn's `input_tokens + cache_read + cache_creation + output_tokens`, not a sum
  across turns: input tokens are re-sent every turn, so adding them up counts
  the same window once per message and shows a healthy session as permanently
  full — a ring that is useless while looking plausible. A turn reporting only
  zeros is skipped rather than drawn at 0% (an agent mid-compaction would
  otherwise claim an empty context), the fraction clamps to 1 so an over-limit
  reading reads as full rather than past the end, and a zero limit yields
  nothing rather than dividing by zero.

  The denominator is the one honest assumption: the log records how many tokens
  each turn used but never how many fit. So the window size is a setting
  (Settings → Agents → Context window, default 200k, zero hides the ring), and
  the footer says outright that it is an assumption to set to your model.

  The ring appears only once a reading has arrived. A session whose log the
  gateway cannot read leaves the slot empty rather than drawing against a number
  nobody measured. Readings are cached one per directory, because a transcript
  read is a file read on the host and the Inbox polls every few seconds — a
  per-row fetch would be a lot of traffic for a number that changes once per
  agent turn. Verified on the simulator against a real gateway and a real
  transcript log: the row shows 91% in the warning colour for a turn of 181k of
  200k tokens. `scripts/context-window-check.sh` pins the arithmetic, and
  `scripts/transcript-check.sh` gained the cases that ensure the gateway passes
  numeric usage through and drops a count that arrives as a string.

- **Native Windows hosts — the resolution decisions.** A gateway on Windows
  needs two things done differently, and both fail only on the platform nobody
  is looking at. `execFile('herdr', …)` never finds the installed `herdr.exe`
  (nor a package-manager `.cmd` shim), so on win32 the probe goes through
  PowerShell's `Get-Command` — the equivalent of `command -v` — instead of the
  bare name. And herdr's API socket is a Unix domain socket on macOS and Linux
  but a *named pipe* on Windows, so the path is derived per platform
  (`\\.\pipe\herdr-<account>`, sanitised so a name with a separator cannot
  escape the pipe namespace, and carrying the account so two users on one
  machine do not collide).

  The decisions live in a new pure `host/cqutmux-hook/platform.mjs` that takes a
  platform string and returns a description without spawning anything — because
  the decisions are the part that breaks, and a checked decision is worth more
  than untestable code. `scripts/windows-host-check.sh` (18 checks) pins the
  program, arguments, presence signal and socket path for each platform.

  **Honest limit:** this repo's gateway has only ever run on Linux and macOS.
  The Windows branch is asserted through the pure functions, *not* end to end —
  no part of this has run on a Windows host. The POSIX path is unchanged, and
  `scripts/herdr-test.sh` still passes against a real herdr server, which is
  what proves the refactor did not break the platform we can run.

- **Passphrase-protected keys, and storing the passphrase.** The docs say an
  optional passphrase can be saved with a connection and an encrypted private
  key can be used; neither was true. Import accepted only unencrypted keys, the
  parser threw "encrypted keys are not supported yet" on any non-`none`
  cipher, and `Host` had nowhere to put a passphrase.

  The reason this is more than a flag is that OpenSSH does not encrypt a key
  with PBKDF2. It derives the AES key *and* IV from one `bcrypt_pbkdf` call — a
  variant of bcrypt where the password and salt are each SHA-512'd, fed through
  Blowfish, run for 64 rounds of key-schedule expansion against the magic text
  `OxychromaticBlowfishSwatDynamite`, and then written to the output
  *non-linearly* so no byte can be computed without computing all of them. There
  is no shortcut and no "close enough": one wrong constant or a wrapping add
  written as a trapping add yields 32 bytes that are simply not the key, and the
  failure surfaces much later as the server rejecting a password. So this needed
  a real Blowfish (`Blowfish.swift`, tables generated from the digits of π
  rather than transcribed), the derivation (`BcryptPBKDF.swift`) and AES-CTR
  (`AES.swift`, S-box derived from the field so it cannot be mistyped).

  It is pinned against things outside this repo, because nothing inside it could
  tell a correct derivation from a plausible one. `scripts/key-import-check.sh`
  now checks two published `bcrypt_pbkdf` vectors — including one whose output
  crosses a block boundary, which the natural mistake of writing blocks in
  order passes the first vector and fails — decrypts a real `ssh-keygen -N`
  fixture to exactly the `.pub` file `ssh-keygen` wrote beside it, and
  round-trips an encrypted export through `ssh-keygen -y` and `ssh-keygen -p`.
  Writing this found the bug the design invited: `bcrypt_hash`'s next salt is
  the SHA-512 of the previous round's *raw* output, not of the running XOR
  accumulator, and hashing the accumulator — which is what this first did —
  matches nothing while looking entirely reasonable.

  On the app side, `KeyMaterial.swift` (Foundation plus the transport package,
  so `scripts/passphrase-check.sh` can build the shipped file rather than a
  copy) decides what a stored key needs. An encrypted key is stored *as the
  PEM*, with its passphrase in a second Keychain entry, rather than being
  decrypted once at import and reduced to a seed. That keeps the passphrase a
  real second factor — the key cannot be opened from the seed alone — and it is
  what makes "remember the passphrase" a setting rather than a thing the import
  silently discards. The connect flow prompts when it has to and remembers by
  default; the key screen recognises an encrypted key by *trying* it with an
  empty passphrase, so the field appears without the user having to declare it.

  **Honest limit, and one deliberate divergence.** The host CLI's `pair` still
  refuses an encrypted key. Its entire output is a link carrying the seed in
  cleartext — it says so itself — so decrypting the file first would only move
  the secret from one plaintext container to another, at the cost of a second
  bcrypt implementation in a language whose stdlib does not have one. The
  refusal now names the fix (`ssh-keygen -p -N ""`) instead of just failing.
  Verified on the simulator against a real sshd: with the encrypted fixture's
  public half in `authorized_keys`, the server logged `Accepted publickey …
  SHA256:roc54/MThSvFLR19ftDCy5ByyCMb69ai+KMhnkn6BFE` — the fixture's own
  fingerprint — and the connect screen shows the passphrase field with
  "Remember in Keychain" on. The four resolve cases (correct passphrase,
  wrong passphrase, none, bare seed) each report the expected
  requirement and either the right public key or no seed at all.

- **Bundled terminal fonts, with JetBrains Mono as the default.** The docs say
  the default font is embedded JetBrains Mono and that Iosevka, Ioskeley and
  DejaVu Sans Mono download on first selection. Neither half was true: the
  family list stopped at the four faces iOS ships, the default was `.system`,
  and there was not a single font binary in the repo.

  All four families now ship *inside* the app — ten faces, 9.4MB — rather than
  downloading. That is a deliberate divergence, and it is the point: the claim
  itself calls JetBrains Mono "embedded", and a download the user never asked
  for is a worse first launch than a bundle that is 9.4MB larger. The
  faces land at the bundle root through `UIAppFonts`, so JetBrains Mono resolves
  on the very first frame; the other three register the first time they are
  picked, because nine more registered faces is launch time and memory spent on
  fonts almost nobody has chosen. Each licence travels beside its font.

  Fonts fail silently in a way almost nothing else does — `UIFont(name:)`
  returns nil, Core Text hands back the system monospaced face, and the user
  sees plain text and concludes the picker is decorative. So the check
  (`scripts/fonts-bundled-check.sh`, 94 checks) reads the font binaries
  themselves: the `name` table for the PostScript name the code looks up by, the
  `cmap` table for what a terminal will actually be able to draw. No font
  library and no device are needed, and it catches the four failures that look
  identical on screen — a file missing from the bundle, a file in the bundle but
  not in `UIAppFonts`, a plist naming a file that is not there, and a
  PostScript name that does not match the font's own.

  Writing it caught my own over-claim twice. I first asserted that the subset
  Iosevka faces kept every codepoint in `0x2500–0x28FF`; upstream never shipped
  all of those, so the check failed for a reason that had nothing to do with
  subsetting. I then set per-range floors from memory, and they were wrong in
  the same direction again — JetBrains Mono has 43 geometric shapes, not 96, and
  35 arrows, not 100. The floors are now *measured* at the weakest of the four
  faces (ASCII 95, Latin 256, Greek/Cyrillic 201, box drawing 128, block
  elements 32, geometric 43, arrows 35), which is the tightest line every face
  can be held to. Braille and the powerline separators are deliberately not
  asserted: JetBrains Mono and DejaVu ship neither and Iosevka only part of the
  powerline range, so demanding them would be a check that cannot pass for a
  reason unrelated to what is being guarded. The subset faces were instead
  compared against upstream `cmap` and found identical in all nine ranges.

  The half that no file check can reach — whether Core Text actually accepts a
  face — was verified on the simulator: all four families resolve to their real
  faces rather than the system fallback, with ten TTFs at the bundle root and
  ten `UIAppFonts` entries.

- **Live control of a simulator, not just watching one.** The docs say taps,
  drags and multi-touch gestures pass from the phone to the Simulator. The
  preview could only display frames and pause.

  There is no supported way to inject a touch: `simctl` can screenshot and
  record but not tap, and neither can anything public. The only route is
  CoreSimulator's private `IndigoHID` API. It loads only into a process the
  Objective-C runtime takes over, and `dlopen`ing SimulatorKit inside node
  crashes at load — which is why this is a separate helper rather than part of
  the gateway. `host/cqutmux-hook/simtouch/` holds its Swift source; the
  gateway builds it on first use, keeps one child per simulator alive while a
  preview is open, and stops it after five idle minutes. The call sequence was
  written against `serve-sim`'s Apache-2.0 `HIDInjector` — the helper Moshi's
  own docs name for simulator preview — and the same mechanism Meta's idb uses.

  **The bug this feature invites, and which I shipped first.** The helper
  printed `{"ok":true}` for every gesture and delivered none of them. The send
  crosses XPC, and the process exited before the run loop turned. A plain sleep
  is also required between a touch-down and its touch-up: a run-loop turn there
  services the device connection mid-touch and drops it. Both failures are
  invisible to anything that stops at the helper's reply, which is exactly what
  a check written alongside the code would have done — so the check compares
  two screenshots around a gesture and *only* that comparison is the assertion.
  Finding it took driving the same gesture through `serve-sim`, which worked,
  and bisecting the difference back to the run loop.

  The app half is a `UIViewRepresentable` with tap/pan/pinch recognisers,
  behind a Control toggle that is off by default — a preview someone opened to
  watch should not turn a stray tap into input on a device they are not looking
  at. Its coordinate mapping goes through the *fitted* frame rather than the
  view's bounds: using the bounds letterboxes every point, so taps land in the
  middle and miss at the edges, which reads as flakiness rather than
  arithmetic.

  `scripts/simulator-touch-check.sh` (15 checks) covers the host half and, on a
  host with a booted simulator, the screenshot comparison.
  `scripts/simulator-touch-app-check.sh` drives both halves through the app
  against a real sshd: phase 1 sends a gesture via the view's own `send`, and
  phase 2 puts a real touch on the phone's preview so the recognisers and the
  mapping are exercised. Both pass.

- **The watch face: a usage complication, and the Live Activity on the Smart
  Stack.** The docs promise a complication for the face and a Smart-card Live
  Activity, both tapping through to the matching screen. The data half already
  existed — `WatchPayload` computes the rate-limit percentages — but nothing on
  watchOS consumed it: the only widget extension was iOS and the Live Activity
  had no `supplementalActivityFamilies`, so nothing of ours could reach a face
  or the Smart Stack.

  A `CQUTmuxWatchWidgets` app-extension target now sits inside the watch app
  (and so, through it, inside the phone bundle). It is a plain WidgetKit widget
  — `StaticConfiguration(kind: "CQUTmuxUsage")` offering the four watch
  accessory families, `widgetURL` on `cqutmux://usage`. That link was added as
  a third deep-link target beside the tmux and inbox ones, and was followed on
  both devices: it lands the iPhone on Usages and the watch app on its Usage
  tab. On the Live Activity side, `AgentActivityView` gained
  `supplementalActivityFamilies([.small, .medium])` and branches on
  `@Environment(\.activityFamily)`, so the same activity that shows as a lock
  screen banner renders as a watch card.

  The container between the two watch processes is an App Group, because
  `WCSession`'s application context is not available to a widget extension.
  `Watch/ApprovalListView` mirrors each payload into it and reloads timelines.
  **The honest limits, since neither is visible from here:** whether a
  complication is *placed on a face* is a user action on the face itself and
  cannot be observed headlessly, so `scripts/watch-complication-check.sh`
  verifies what a build can get wrong — the kind, the four accessory families,
  the link, the entitlement on both targets, the code reading the group the
  entitlements declare, and the appex's `NSExtensionPointIdentifier` — rather
  than claiming the face shows it. And the simulator drops App Group
  entitlements under `-` signing, so the shared container is nil there; the
  read returns nil instead of trapping and the complication draws `—` rather
  than a false zero. `scripts/watch-usage-check.sh` (27 checks) covers the
  shared-container round trip that the simulator cannot.

- **The tab quick-access row, on every multiplexer.** The row was tmux-only and
  nine buttons wide. The page lists twenty for each of the three multiplexers,
  and the reason each button is not simply the same keystroke is that the three
  programs read a tab number three different ways: tmux reads its prefix plus the
  bare digit (and its command prompt past nine), herdr reads its own prefix, and
  zellij — which has no prefix at all — reads `Ctrl-T` plus the number, `Ctrl-T`
  being its tab-mode key rather than one of its `zellij action` line commands.
  That last one is the trap: reaching for `zellij action go-to-tab` would be the
  natural move, since it is what every other zellij command here uses, but that
  line needs a shell to run it and the shell is not what has focus while a TUI is
  on screen. The mapping lives in one function so the row cannot drift from it,
  and the row is drawn wherever that function returns bytes rather than behind a
  `host.mux == "tmux"` test.

  **Two checks, because they fail differently.** The mapping is pure and runs
  through the interpreter (19 checks). The delivery is read off a live host with
  `cat -v`, which renders a prefix as `^B` — a digit that arrived *without* its
  prefix is the bug this row can have, and it is invisible to anything that only
  checks the row exists.

  **The instrument lied first, though.** The zellij probe showed a bare `5`
  where it should have shown `^T5`, which looks exactly like a dropped control
  byte. It was not: under a shell with line editing the tty is in canonical mode,
  and a control byte readline has no binding for is discarded before any program
  sees it — the digit survives because it is text. `stty raw -echo` put the pty in
  raw mode and `^T` appeared. Same class of mistake as the simulator-touch
  helper's `{"ok":true}`: a negative result from an instrument that cannot show
  the positive one.

- **Two-finger swipes drive the multiplexer.** Recorded here as absent twice, and
  wrong both times: the notes enumerated UIKit's stock recognisers and missed
  `UISweepGesture`, a custom two-touch directional recogniser that exists because
  `UISwipeGestureRecognizer` cannot require exactly two touches while also
  reporting which way the drag went and refusing a diagonal. A horizontal sweep
  moves the pane on tmux and herdr and does nothing on zellij — whose pane moves
  live inside a mode whose entry key cannot be sent as one chord — and a vertical
  sweep moves the tab on tmux and zellij and opens herdr's workspace navigator,
  which has no next-workspace key of its own. The gate is consulted before the
  touch begins, so on a plain shell the sweep fails immediately and the
  two-finger drag still scrolls; the mouse-wheel pan is made to wait on both.

- **Herdr's prefix is its own setting.** Also recorded as absent and also
  already implemented — the audit text had gone stale against commit `edf2834`.
  tmux and herdr are separate programs configured by separate files, and a host
  commonly runs both, so sharing one stored prefix would make changing the tmux
  one silently rebind every herdr chord. `Settings → Multiplexer` carries both,
  sync carries both, and every chord and the tab row resolve through
  `prefix(for:)`.

- **The Watch inbox groups by project.** The phone's board has grouped its
  waiting rows by project since `InboxBoard.groups(in:)`, but the push flattened
  them first: `WatchPayload.Snapshot.Item` carried only id/source/title/body/options,
  so the wrist drew one flat list and the headings could not survive the wire. It
  now carries `project` and `at`, and `Snapshot.groups` / `isGrouped` do the
  grouping on the watch side. The ordering is the phone's, in the phone's
  precedence: something waiting first (a no-op here - everything on the wrist is
  waiting), then the unnamed group last, then recency newest-first. One rule is
  deliberately not the phone's: two named groups tied on recency order by name,
  because the phone's comparator falls back to comparing timestamps and leaves
  equal ones to dictionary iteration - which a list rebuilt from a dictionary on
  every push could reshuffle between redraws, so the same two projects could swap
  places while the wearer watched.
  Writing the check found a real bug in that comparator: the first version sorted
  recency ahead of unnamed-last, and the "unnamed last even when its item is
  newest" case failed. The fix was to the code, not the check.
  The claim also named a toolbar icon whose fill mirrors whether events are
  active. `WatchRootView`'s trailing glyph was a static `tab.icon` that reported
  the *selected tab*, so the tray read `tray.full` on an empty inbox - a mark
  that says "there is work" every time the wearer glances down, which is worse
  than showing nothing. It is now `WatchPayload.inboxGlyph(hasItems:)`.
  Pinned by `scripts/watch-inbox-check.sh` (26 checks) over the Foundation-only
  payload the watch target compiles; the same clip runs as a SwiftUI
  `ForEach(groups) { Section { ForEach(group.items) } }` in `ApprovalListView`,
  with no header drawn when there is only one group.

- **The host locale, half of it.** The claim is two halves, and only one is now
  built. `IntegrationSettings` carries a stored locale and derives both `LANG`
  and `LC_ALL` from it — the pair, because a host whose `/etc/profile` sets its
  own `LC_ALL` would otherwise ignore the `LANG` we sent, and that is exactly the
  host where a mis-set locale bites. The value rides every path that carries an
  environment: SSH's request, Mosh's `-l` list (where the launcher used to
  hardcode `LANG=en_US.UTF-8` and *skip* a configured one, so the setting would
  have looked applied and done nothing), and the line typed at the session's
  first prompt.
  It is empty by default for the same reason the client marker is off by
  default: setting a locale a host does not have installed makes every command
  print a `setlocale` warning, so defaulting it on would turn an upgrade into a
  regression on exactly the minimal hosts most likely to lack it.
  A locale is only sent if it is a UTF-8 name made solely of locale characters —
  the value is pasted into a shell line unquoted, so `C` (which would mojibake
  the terminal) and `en_US.UTF-8; rm -rf /` are both dropped rather than
  sanitised. Writing the check caught a real bug here: `isUTF8` read to the end
  of the name, so it saw `UTF-8@euro` and rejected every modified locale such as
  `de_DE.UTF-8@euro`. `scripts/integrations-check.sh` is now 41 checks, and
  reverting that fix reddens exactly the one case covering it.
  **Still open:** the claim's second half, writing the exports into `~/.zshenv`
  and a non-interactive `~/.bashrc`. No helper writes any rc file, so shells the
  agent spawns still see the host's own locale.

- **Per-agent Usages windows.** Every source used to be measured against the
  same fixed 5h/7d pair — Claude Code's limits, stated on behalf of agents that
  do not have them. `host/cqutmux-hook/usage.mjs` now holds one window set per
  source string the hooks emit: Claude Code keeps 5h/7d; Codex gets a variable
  set with human labels (`5h`, `weekly`); Kimi Code a weekly window; Grok Build a
  credit window, flagged so it is not read as a rate limit that refills; OpenCode
  a single provider-agnostic rolling window rather than an invented pair. An
  agent the host does not model falls back to Claude's set, because an empty card
  reads as "no usage" — a different and false statement.
  The flag crosses both surfaces: `HookClient.UsageWindow` decodes it (defaulted,
  so a host that predates the field still decodes), the phone words it
  "% credits", and it rides the shared watch payload to render as "% cr".
  `scripts/usage-check.sh` (29 checks) runs plain node with no gateway, and
  making `windowsFor` return the default for every source reddens 7 of them.

- **What is listening, not just which port is open.** The port scan returned bare
  numbers, and the phone tagged a hard-coded set (3000, 5173, …) "dev" whether or
  not a dev server was on it — which cannot tell the server you started from a
  system daemon. `host/cqutmux-hook/listeners.mjs` now reads `lsof`/`ss` into
  sockets carrying the process command, pid and bind address, probes each for
  HTTP, and labels the framework; `PreviewView` shows that name beside the port,
  with a lock glyph for a loopback-only listener, since a server bound to
  `127.0.0.1` is not reachable through the SSH session even though its port is
  open.
  Writing the check caught a real bug: `lsof` prints the process name as the
  kernel holds it, so `Google Chrome` is one command spanning two columns — the
  first parser split on whitespace and reported a pid that belonged to nothing.
  It now anchors on the first all-digit field. `scripts/listeners-check.sh` (43
  checks) runs plain node; assuming single-word commands reddens exactly the two
  cases covering it.

- **`cqutmux diff` opens a viewer in the browser.** It used to print the changed
  file list and tell the user to go and look at the app — a recorded deliberate
  divergence, since the app has its own viewer. But the doc page describes a
  one-shot browser viewer on a stable loopback port, and it is the CLI that is
  being tested, so the divergence was the gap. `host/cqutmux-hook/diffpage.mjs`
  renders a self-contained page; `diff()` serves it on `127.0.0.1`, prints the
  URL, opens the browser, and holds until Ctrl-C. `--port N` (0 = any free port)
  and `--no-open` both work.
  The reason the rendering is a separate, tested module: a diff is arbitrary
  repository text, and a page built by concatenation breaks — or *runs* — on what
  it displays. A `<script>` in a source file, or in a *filename* (which the
  filesystem allows and the page puts in an element id), is escaped, and a line's
  leading `+`/`-` is treated as the diff's mark rather than as content.
  `scripts/diffpage-check.sh` (36 checks) runs plain node with no browser;
  removing the escaping reddens 9 of them. The end-to-end smoke test found two
  real bugs: the subcommand dispatcher calls `process.exit` when a command
  returns, so the server was killed the instant it started — the command now
  holds until a signal; and a clean tree rendered an empty `<ul></ul>`.

- **`cqutmux context`, the daemon-less terminal probe.** The `cqutmux <dir>`
  launcher existed; the probe did not. `host/cqutmux-hook/context.mjs` reads the
  shell's own environment — `ZELLIJ`/`ZELLIJ_PANE_ID`, `TMUX`/`TMUX_PANE`,
  `HERDR_ENV`/`HERDR_SESSION`/`HERDR_PANE` — and prints `{kind, session, pane,
  cwd}` as JSON, contacting no gateway: the point is that it answers from a
  prompt or a status line when nothing else is running.
  The rule that fails silently is precedence when multiplexers nest: a zellij
  inside a tmux pane has *both* sets of variables, and reporting the outer frame
  is valid JSON naming the wrong place. Zellij wins, because it is the innermost
  session and the one the keystrokes go to. For tmux the session *name* is asked
  of tmux (`display-message -p '#{session_name}'`), since `$TMUX` carries only
  the session index; the index is the fallback when that query fails.
  `scripts/context-check.sh` (32 checks) runs plain node; checking tmux before
  zellij reddens the 3 nested cases.

### The 15 that are still open, grouped by what is actually missing

A second independent pass on 2026-10-10 rewrote each of these with file:line
evidence. What is missing, in one line each:

**Half-built (the surrounding feature works, the named part does not)**
- The session picker has no Recent tab; recents live in the Code page's Go To
  Directory sheet.
- The app resumes a backgrounded session on foreground, but nothing restores the
  last host/session at cold launch.
- Chat mode's composer takes typed text only — the mic and image buttons are in
  the bar it replaces.
- The interactive session can now be given a locale (`Settings → Integrations`, exported as both `LANG` and `LC_ALL` and carried by SSH and Mosh), but nothing writes `~/.zshenv` or a non-interactive `~/.bashrc`, so shells the agent spawns itself still see the host's default locale. The rc-injection half is unbuilt.
- The diff viewer does take the custom font (that half is done); `.ttc`/`.otc`
  handling and the fallback are not.
- Theme import is complete; the 570-theme `/themes` gallery it can import *from*
  does not exist.
- Inbox rows now carry all five named categories (approval_required,
  task_complete, session_started, tool_running, tool_finished) as well as the
  needs-you/working/done column, which is derived from them.
- Chat View renders message blocks and now separates Markdown prose from
  fenced code and inline images; the remaining gaps there are the mini diffs,
  task groups and plan cards of entry 54.
- Chat View opens both from the terminal toolbar's agent icon and from the Code
  pane's Chat segment, and its header now names the agent, the newest model and
  the session and carries the diff and browser-preview controls.
- Tool cards now draw the call's shape: an edit as a mini diff with a
  `+n −m` collapsed row, a todo list as a checklist, a plan as rendered
  Markdown. An unrecognised tool still falls back to the raw-JSON card.
- Side-by-side diff and line-level modify highlights are absent.
- The Browse tab walks the tree and opens files, but as plain monospaced text —
  no syntax highlighting, no historical commits.
- The Live Activity shows a pending approval but is static — it cannot be
  answered from the Lock Screen or the Island.
- The Live Activity now carries the four lifecycle phases — approval needed,
  working, done and session ended — in addition to the pending count, so
  task-complete and tool-running events reach it and a finished session lingers
  before dismissing. What it still cannot do is take the answer: the Lock Screen
  and the Island show the approval but the buttons remain in the app (entry 61).

**Genuinely absent**
- APNs push-to-start. No token registration on either side; the host's APNs
  sender emits alert pushes only. This is the one `missing` entry.
