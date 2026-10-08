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
| 2 | Mosh / ET transports | ⛔ blocked — needs a C/C++ cross-compile toolchain the host lacks. Roaming is covered instead by backoff auto-reconnect. |
| 3 | Host gateway + agent Inbox / Diff / Files / History | ✅ |
| 4 | Notifications, Live Activity, voice, image paste, tmux picker | ✅ |
| 5 | zellij, iPad sidebar, browser + simulator preview, gateway token | ✅ |

Each phase was exercised in the simulator against a real sshd on a loopback
port, with the host gateway live. See [PLAN.md](PLAN.md) for what is verified
and what is not.

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
  Features/Terminal/    the terminal, accessory bar, session picker
  Features/Agents/      inbox, gateway client, notifications, Live Activity
  Features/Code/        files, diffs, git history
  Features/Preview/     browser bridge and simulator preview
  Features/Security/    Keychain, key management
Packages/CQUTTransport/ local SwiftPM package: the SSH transport
host/cqutmux-hook/      host-side gateway daemon (Node.js)
Widgets/                Live Activity / Dynamic Island extension
scripts/                bootstrap / build / run
```

## License

TBD.