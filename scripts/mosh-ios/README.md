# mosh on iOS

Cross-compiles mosh's **client-side libraries** for iOS and runs them in
process. This exists because iOS cannot fork/exec, so the stock `mosh-client`
binary — which is `fork(); exec("ssh", …)` plus a `select()` loop on a real
tty — can never run here. The libraries can, and do.

## What is built

`libmoshclient.a`, 27 objects, containing:

| Directory | What it gives |
|---|---|
| `crypto` | `Crypto::Session` (AES-128-OCB3), base64, PRNG |
| `terminal` | the VT parser, `Framebuffer`, `Display`, predictions |
| `statesync` | `Complete`, `UserStream` — the two state machines |
| `network` | `Transport`, compression, fragment reassembly |
| `protobufs` | generated from mosh's `.proto` files |

`nm` on the archive shows `Terminal::Framebuffer`, `Terminal::Display`,
`Network::Transport` and the rest present as defined symbols.

## How the hard parts were solved

- **Crypto.** mosh has an `apple-common-crypto` backend, and `configure.ac`
  makes it the default on Apple platforms. That removes the OpenSSL and Nettle
  cross-compiles entirely. The OCB mode comes from mosh's own bundled
  `ocb_internal.cc`, so `ocb_openssl.cc` is excluded rather than compiled.
- **protobuf.** Pinned to 21.12 — the last release before protobuf took a hard
  abseil dependency, which is the change that makes later versions painful to
  cross-compile. Built as `protobuf-lite`, which is what mosh's `.proto` files
  request (`optimize_for = LITE_RUNTIME`). `protoc` must match the runtime
  exactly; a newer generator emits headers the runtime rejects.
- **termconfig.** No autoconf. `config-ios.h` states the facts directly,
  because configure probes for pty.h/utempter/libutil/utmpx — the *server's*
  needs, absent on iOS — and would enable code that can't link.
- **terminfo.** iOS ships `libncurses.tbd` (it exports `setupterm`,
  `tigetstr`, `tigetflag`) but no headers and **no terminfo database**, and
  mosh wants a terminal before its first byte of output. `terminfo-shim.c`
  implements the three calls against a compiled-in xterm-256color entry, so
  the database problem doesn't arise. No cross-compiled ncurses needed.

## Verified

```
$ scripts/mosh-ios/fetch-deps.sh /tmp/moshbuild
$ scripts/mosh-ios/build.sh /tmp/moshbuild/mosh-1.4.0 /tmp/moshbuild/out
$ xcrun simctl spawn <device> /path/to/linktest
terminfo ok
```

A test program linking the archive + `libprotobuf-lite.a` builds a
`Terminal::Complete`, feeds it bytes, and exercises the terminfo shim — and
runs on the iOS simulator.

## Not yet done

The libraries are proven; the **transport is not wired into the app**. What
remains is a C++ driver that replaces `stmclient.cc`'s `main()`:

- `stmclient.cc` is `main()`: `select()` on `STDIN_FILENO`/`STDOUT_FILENO`
  plus `tcgetattr`/`tcsetattr` on fd 0. Over a socket those fds aren't ttys and
  the termios calls fail, so it needs a driver exposing `init / feedBytes /
  sendKeys / resize / frame`, with I/O owned by the Swift side.
- The UDP socket is fitted with `Network::Transport`'s file descriptor rather
  than created by it.
- Frames (`Display::open/new_frame/close`, which already return `std::string`)
  feed into SwiftTerm's parser, whose output is already travelling over the
  existing SSH transport.