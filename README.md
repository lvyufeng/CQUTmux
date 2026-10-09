# CQUTmux

A mobile terminal for AI coding agents — a clean-room reimplementation of
[Moshi](https://getmoshi.app) (`app.getmoshi.ios`), rebuilt as an open project.

Check on Claude Code from the couch. Drive tmux over SSH/Mosh/ET from your phone.
See plan: [PLAN.md](PLAN.md).

> **Note on provenance:** this project is built from public documentation, the
> App Store listing and original code. No decrypted/rehosted IPA was used.

## Status

| Phase | Scope | State |
|---|---|---|
| 0 | Project skeleton, SwiftUI shell, host CRUD | ✅ |
| 1 | SSH terminal MVP (swift-nio-ssh + SwiftTerm + tmux) | ✅ |
| 2 | Mosh / ET transports | ✅ both behind `TerminalTransport`, selected per host; mosh verified end to end against a real `mosh-server`, ET against a real `etserver`/`etterminal` |
| 3 | Host gateway + agent Inbox / Diff / Files / History | ✅ |
| 4 | Notifications, Live Activity, voice, image paste, tmux picker | ✅ |
| 5 | zellij + herdr, iPad sidebar, browser + simulator preview, gateway token | ✅ |
| 6 | Apple Watch approvals | ✅ full round trip driven in the watchOS simulator (phone → wrist → approval → `POST /approve/<id>`) |

Each phase was exercised in the simulator against a real sshd on a loopback
port, with the host gateway live. `scripts/` holds a check script per area;
each one ends in a `<AREA>_PASS` line. See [PLAN.md](PLAN.md) for what is
verified and — recorded just as carefully — what is not.

## Architecture

The app talks to a small host-side gateway, `cqutmux-hook`, which binds to
`127.0.0.1` only. The phone reaches it through the SSH session it already has
(`direct-tcpip` port forwarding), so no agent traffic ever crosses a relay and
the gateway is never exposed to the network. The same tunnel backs the browser
and simulator previews.

- **Transport:** [swift-nio-ssh](https://github.com/apple/swift-nio-ssh)
  (pure Swift — no OpenSSL to cross-compile)
- **Terminal:** [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
- **Gateway:** Node.js, no dependencies

## Requirements

- Xcode 26+ (built against Xcode 27 / iOS 27 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `scripts/bootstrap.sh` fetches it if missing
- Node 18+ for the host gateway

## Build

```sh
./scripts/bootstrap.sh          # fetch xcodegen, generate CQUTmux.xcodeproj
./scripts/build.sh              # build for the iOS simulator
./scripts/run.sh                # build, install and launch on a booted simulator
```

## Layout

```
App/                    SwiftUI app (features grouped by domain)
  Features/Terminal/    the terminal, accessory bar, session picker, Jump To
  Features/Agents/      inbox, gateway client, notifications, Live Activity
  Features/Code/        files, diffs, git history, pasted files
  Features/Preview/     browser bridge and simulator preview
  Features/Security/    Keychain, key management
  Features/Settings/    theme, font (+ custom font import), cursor, speech, iCloud sync, integrations, input
  Features/Voice/       dictation engines (Apple / Whisper / Parakeet / cloud)
Packages/CQUTTransport/ local SwiftPM package: the SSH transport, agent forwarding
Packages/CQUTMosh/      the mosh↔Swift driver (C); see scripts/mosh-ios/
Packages/CQUTET/        Eternal Terminal; see scripts/et-ios/
Packages/CQUTWhisper/   whisper.cpp + Parakeet, via a C seam
host/cqutmux-hook/      host-side gateway daemon and CLI (Node.js, no deps)
Widgets/                Live Activity / Dynamic Island extension
Watch/                  watchOS app: approve agent requests from the wrist
scripts/                bootstrap / build / run, plus one check script per area
```

## License

TBD.