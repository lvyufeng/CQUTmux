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
| 0 | Project skeleton, SwiftUI shell, host CRUD | 🚧 in progress |
| 1 | SSH terminal MVP (libssh2 + SwiftTerm + tmux) | planned |
| 2 | Mosh / ET transports, tmux picker | planned |
| 3 | Host hook gateway + agent Inbox / Diff / Files | planned |
| 4 | Notifications, Live Activity, voice, image paste | planned |
| 5 | herdr, gestures, iPad sidebar, Tailscale | planned |

## Requirements

- Xcode 26+ (built against Xcode 27 / iOS 27 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `scripts/bootstrap.sh` fetches it if missing

## Build

```sh
./scripts/bootstrap.sh          # fetch xcodegen, generate CQUTmux.xcodeproj
./scripts/build.sh              # build for the iOS simulator
./scripts/run.sh                # build, install and launch on a booted simulator
```

## Layout

```
App/                    SwiftUI app (features grouped by domain)
Packages/               local SwiftPM packages (transport, terminal, hook client…)
host/cqutmux-hook/      host-side gateway daemon (Go)
scripts/                bootstrap / build / run
```

## License

TBD.