# ET on iOS — what was found, and what is left

Eternal Terminal is **not** blocked by cross-compilation, which is what this
directory originally existed to find out. It is blocked by its shape.

## The finding

ET's client (`src/terminal/PseudoUserTerminalUnix.hpp`) is built on `forkpty`:
it spawns a shell on a *local* pty whose master fd it then pairs with the
remote end. iOS has neither `fork` nor `exec`, so this cannot be linked as-is,
and no amount of build plumbing changes that.

What that means in practice: ET needs the same treatment mosh got — a driver
that replaces the local pty with the app's own terminal, keeping the protocol,
crypto and reconnect logic. mosh's driver is `scripts/mosh-ios/driver/`; ET
would need its analogue, at similar cost.

## What is already done

The dependency that is genuinely hard to cross-compile is libsodium: it is
autoconf-based and decides which primitives to enable by *running* test
programs, which cannot run for another platform.

`libsodium.sh` handles it and is verified:

    scripts/et-ios/libsodium.sh <libsodium-src> <out-dir> [simulator|device]

It produces a `libsodium.a` carrying 13 `crypto_secretbox_xsalsa20poly1305`
symbols — the primitive ET's handshake uses — and refuses to finish if the
count is zero, because a configure that guessed wrong still emits an archive.

The remaining dependencies (zlib, libc++, pthread) are on iOS already, and
protobuf-lite is built by `scripts/mosh-ios/`.

## What is left

1. A driver over ET's client core, replacing the `forkpty` lifecycle with the
   app terminal's — the same shape as `mosh_driver.cc`.
2. An `ETTransport` implementing `TerminalTransport`, and a launcher that
   starts `etserver` on the host over an SSH `ExecRequest` (the mechanism
   `SSHMoshLauncher` already provides).
3. The reconnect story, which is ET's selling point over a strict network and
   is the reason it is worth doing rather than skipping.
