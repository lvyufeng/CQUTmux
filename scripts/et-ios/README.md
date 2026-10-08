# ET on iOS

Eternal Terminal's client core runs on iOS, and was verified end to end against
a real `etserver` on 2026-10-09 (see "Verification" below).

## The finding that mattered

ET is **not** bound to a local pty, which is what this directory originally
concluded and later had to correct. The `forkpty` code lives behind
`src/terminal/Console.hpp`, an abstract interface whose own comment says it
exists so that "TerminalClient or terminal emulators" can drive the client —
and ET's own `test/FakeConsole.hpp` does exactly that. So the same shape of
work mosh needed applies: supply the front end, keep the protocol, crypto and
reconnect logic.

`PseudoUserTerminalUnix.hpp` is the *remote* end's pty, not the client's. The
client's is only what the stock `et` binary passes in.

## What is here

| File | What it does |
|---|---|
| `libsodium.sh` | Cross-compiles libsodium for iOS. Verified by symbol count, because a configure that guessed wrong still emits an archive. |
| `host-tools.sh` | Builds `etserver`/`etterminal` for macOS. ET ships no Darwin release asset, so the server side has to be built to test against. |
| `build.sh` | Builds ET's client core + `driver/` into `libetcore.a`. |
| `driver/et_driver.h`, `et_driver.cc` | The C surface over ET's client, and the `Console` implementation that replaces the pty. |
| `driver/telemetry_stub.cc` | The two telemetry symbols ET references despite `-DNO_TELEMETRY`. |
| `test.sh`, `e2e-test.cc` | Drives the iOS binary against a live `etserver`. |

## Verification

`scripts/et-ios/test.sh` builds the client as an arm64-iOS simulator binary and
connects it to a real server. It checks three things, and each fails
independently:

1. **Output** — the server opens a login shell whose prompt arrives unprompted.
2. **Input** — the harness types `echo ET_E2E_$((10+1))_OK` and requires
   `ET_E2E_11_OK` back. The arithmetic is the point: the client never produces
   "11", so it can only appear by reaching the server and running.
3. **Resize** — the session survives `et_push_resize`, proven the same way.

## The traps, in the order they bite

None of these produce an error that names them; each took a detour to find.

- **`noPty` must be false.** `TerminalClient` sends `no_pty` to the server, and
  `TerminalServer` rejects `no_pty` with an empty command outright. Leaving the
  *remote* shell on its pty is correct — the pty iOS cannot provide is the
  local one. `noPty` is only for raw byte piping (`et ... cmd > file`).
- **The stdin line to `etterminal` is `<id>/<passkey>_<TERM>`.** The `_<TERM>`
  half is not optional; `parseTerminalStdinLine` rejects a line without it.
- **The `IDPASSKEY:` banner arrives with a CR on the end** when read through a
  pty, because the pty translates `\n` to `\r\n`. A 33-byte passkey where the
  crypto wants 32 fails the handshake with a generic "Connect timeout" that
  says nothing about the cause.
- **`Console`'s vtable lives in `ConsoleUnix.cpp`.** The header declares
  virtuals and defines only some inline, so any iOS subclass needs that object
  linked or it fails with a missing `typeinfo for et::Console` pointing at the
  subclass.
- **`PortForwardHandler` and both forwarding handlers are required** even
  though the app opens no tunnel: `TerminalClient::run` calls
  `hasActiveStdioForward()` unconditionally.
- **`TelemetryService` must be created before the client.** ET's `main` does
  it; the driver stands in for `main`, so it must too, or the first connection
  aborts with "Tried to get a singleton before it was created".
- **ET's generated protobuf uses the full runtime, not lite** — and mosh's
  build only ever produced `libprotobuf-lite.a`.
- **`CPPHTTPLIB_OPENSSL_SUPPORT` in `Headers.hpp` must be scoped to iOS, not
  removed.** On macOS it is load-bearing: httplib's `Client` constructor
  *throws* on an `https://` URL when built without a TLS backend, and
  `TelemetryService` constructs one with a hardcoded `https://` URL before its
  `NO_TELEMETRY` check can return — so `etserver` dies at startup and never
  listens. See `host-tools.sh` for the other two host-build problems.

## What is left

- The Swift side: `ETTransport` implementing `TerminalTransport`, and an
  `ETLauncher` starting `etterminal` over an SSH `ExecRequest` (the same
  mechanism `SSHMoshLauncher` already provides for mosh, with the
  `IDPASSKEY:` readback at the point where mosh reads `MOSH CONNECT`).
- A device build of `libetcore.a`, which `build.sh device` supports but which
  has not been exercised the way the mosh archives have.