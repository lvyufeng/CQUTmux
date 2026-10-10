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
  per-user LaunchAgent / systemd unit and loads it. `host/cqutmux-hook/service.mjs`,
  `scripts/service-check.sh` (50 checks).
- **`unpair`** — pairing had no way back. Now removes exactly the cqutmux line
  from `authorized_keys`, keeping the key pair unless `--delete-key`.
- **A `cqutmux` launcher on PATH** — `install` now writes a shim to
  `~/.local/bin/cqutmux`, so the documented `cqutmux <dir>` is a command the
  user can type. It pins `process.execPath` rather than using a `env node`
  shebang, which resolves through a PATH a service or login shell may not share.
- **`cqutmux diff`** was already a browser viewer; the *check* for it was stale
  and hung. Fixed in `scripts/cli-check.sh` (drives the server and asserts it
  stops on SIGTERM).

## Genuinely open (verified present, not implemented)

Each was confirmed by a verifier that searched the working tree for a
counterpart under another name and found none.

| Gap | Evidence |
|---|---|
| Session picker has no per-multiplexer tab and no "Skip" | `SessionPickerView.Tab` is `case sessions, recent` only; zellij sessions *do* appear, in the shared list. No `Skip` action anywhere. |
| Scroll-past-bottom keyboard dismissal is not configurable | `keyboardDismissMode = .interactive` set once at `CQUTTerminalView.swift:147`; the scrolling doc calls it configurable. |
| Notifications: no push-token display, no image test, no simulator guard | `deviceToken` is `private(set)` and the UI shows only "Registered"; `sendTest()` posts text-only; no `targetEnvironment(simulator)` guard. |
| Support: no log export, no transcript collection, report is a fixed fact list | `SupportView.swift` builds a fixed version/device/system/host block; no Subject/Setup/Expected/Actual template; no log surfaces. |
| tmux defaults writers (history-limit / mouse / base-index) | No `~/.tmux.conf` writer; the only line written is the unrelated `update-environment CQUTMUX_CLIENT`. |
| Deep links have no `pane` / `tab` parameter | `DeepLink.Target.session` carries only `mux/name/window`. |
| `moshi-hook service` on Windows | Moshi registers a per-user logon entry; we report the platform unsupported rather than fake it. |

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