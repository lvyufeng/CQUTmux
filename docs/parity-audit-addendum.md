# Parity audit — addendum

`docs/parity-audit.md` covers "all 42 pages" as of 2026-10-09. The site has since
grown: `sitemap-content.xml` listed **43 docs pages** on 2026-10-11, and the main
audit's page groups cover ~27 of them. This addendum records a pass over the
pages that were never audited, run 2026-10-11 with the same standard the main
audit uses: every claim needs real `file:line` evidence, and every claimed gap
was handed to a verifier whose only job was to refute it by finding the
implementation under another name.

## Pages covered here for the first time

`tailscale`, `install`, `troubleshooting`, `debug-gateway`,
`debug-multiplexer-chooser`, `debug-chat-view`, `install-moshi-hook`,
`install-desktop`, `subscription`, `skill`, `tmux`, `zellij`, `scrolling`,
`notifications`, `report-a-bug`, `licensing`.

## Closed since the main audit

- **`doctor`'s Multiplexers section** — the single largest host gap. The picker
  resolves tmux/zellij/herdr through an `sh -lc` preflight with a fixed PATH
  prepended; the daemon resolves them from its own environment, and when the two
  disagree the session tab silently never appears. `cqutmux doctor` now
  reproduces the preflight and reports the disagreement, telling apart
  *daemon-cannot-find*, *duplicate*, and *version-mismatch* from *absent*.
  `host/cqutmux-hook/doctor-mux.mjs`, pinned by `scripts/mux-doctor-check.sh`
  (44 checks).
- **`service install|status|uninstall`** — Moshi's `moshi-hook service install`
  registers a service; ours only printed a snippet to paste. Now writes a
  per-user LaunchAgent / systemd unit and loads it, and on Windows a per-user
  `HKCU\...\Run` logon entry (no elevation, matching Moshi). `host/cqutmux-hook/service.mjs`,
  `scripts/service-check.sh` (69 checks). The Windows branch has never been
  executed on Windows — only its rule-level decisions are asserted here.
- **`tmux-defaults`** — Moshi's `moshi-skill` recommends four `~/.tmux.conf`
  settings; ours had no writer (the only line written was the unrelated
  `update-environment CQUTMUX_CLIENT`). Now shows, writes and removes them in a
  delimited block that never rewrites or reorders the user's own lines, and
  treats a setting already present — even at another value — as their choice to
  keep. `host/cqutmux-hook/tmux-defaults.mjs`, pinned by
  `scripts/tmux-defaults-check.sh` (50 + 12 checks).
- **`unpair`** — pairing had no way back. Now removes exactly the cqutmux line
  from `authorized_keys`, keeping the key pair unless `--delete-key`.
- **A `cqutmux` launcher on PATH** — `install` now writes a shim to
  `~/.local/bin/cqutmux`, so the documented `cqutmux <dir>` is a command the
  user can type. It pins `process.execPath` rather than using a `env node`
  shebang, which resolves through a PATH a service or login shell may not share.
- **`cqutmux diff`** was already a browser viewer; the *check* for it was stale
  and hung. Fixed in `scripts/cli-check.sh` (drives the server and asserts it
  stops on SIGTERM).

## Gaps this pass found — all since closed

At the time of the audit (`ffd8af1`) each of these was confirmed still open by a
verifier that searched the working tree for a counterpart under another name and
found none. They have since been implemented; the table is kept as the record of
what the pass found, with the commit that closed each. The *Evidence* column
describes the state **as found**, not as it is now.

| Gap as found | Evidence at `ffd8af1` | Closed by |
|---|---|---|
| Session picker has no per-multiplexer tab and no "Skip" | `SessionPickerView.Tab` was `case sessions, recent` only; zellij sessions appeared in the shared list. No `Skip` action anywhere. | `3830cb9` (per-mux tabs), `8614641` (Skip starts a plain shell) |
| Scroll-past-bottom keyboard dismissal is not configurable | `keyboardDismissMode = .interactive` set once; the scrolling doc calls it configurable. | `6b5da96` (Input setting → `.interactive`/`.none`) |
| Notifications: no push-token display, no image test, no simulator guard | UI showed only "Registered"; `sendTest()` posted text-only; no `targetEnvironment(simulator)` guard. | `543fcc9` (token display, image test, simulator guard) |
| Support: no log export, no transcript collection, report is a fixed fact list | `SupportView.swift` built a fixed version/device/system/host block; no Subject/Setup/Expected/Actual template; no log surfaces. | `543fcc9` (template, transcript), `932d0a5` (unified-log export) |
| Deep links have no `pane` / `tab` parameter | `DeepLink.Target.session` carried only `mux/name/window`. | `3b76647` (`tab` alias, tmux `pane`), `c2074f4` (herdr `pane`, parsed *and* consumed) |

Each closure was re-verified against the working tree on 2026-10-11 by a
verifier reading the code, not the commit messages; every sub-claim came back
closed. Two caveats stand and neither reopens a row: the herdr pane jump needs a
live gateway client and shows a notice without one (a designed, reported
fallback), and the push-token display only shows a token once APNs has issued
one, so without a paid profile it correctly reads "Not registered".

(`moshi-hook service` on Windows was in the earlier draft of this table and is
now closed — see above. It is recorded there, not here, because the entry is
built and rule-checked; the only thing still unverified is running it on a real
Windows machine.)

## Claims that were FALSE (refuted, do not record as gaps)

- **`install --target <agent>`** — not documented by Moshi; the first-pass
  audit read it out of the debug pages and inferred a flag that does not exist.
- **"`doctor` has no multiplexer section at all"** — the first-pass claim
  misread `multiplexers()` (`index.mjs`, the `/sessions` HTTP handler) as
  doctor support. The gap was real but the reasoning was wrong, and the fix is
  the section above.
- **`suppress-push-while-unlocked`** — the capability exists as
  `PushCoordinator.isPaused` / "Pause notifications" (`PushRegistration.swift`,
  enforced in `AppDelegate.swift`). Already recorded as `partial`.

## Deliberate divergences (unchanged, re-confirmed)

StoreKit / licensing and the subscription surface; the Desktop control room on
`:24544`; the hosted webhook ingest, image-push CDN and rate limits; the
`moshi-skill` package. All need Moshi's hosted service or a second product, and
are recorded at `IntegrationSettings.swift` and in the main audit.