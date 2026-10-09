# Parakeet on iOS

Where this stands: **the engine is built, vendored, and verified transcribing on
the iOS simulator — but it is not wired into the app, because the app already
ships a different ggml and two of them cannot be statically linked.**

Moshi's docs call Parakeet "the engine we currently recommend for English and
many European languages … the best balance of speed and accuracy", and it is one
of four engines it offers. So this is a real gap, not a nicety.

## What is verified

```
scripts/parakeet-ios/build.sh /tmp/parakeet_probe/parakeet.cpp /tmp/parakeet_probe/vendor simulator
scripts/parakeet-ios/check.sh /tmp/parakeet_probe/vendor \
  /tmp/parakeet_probe/models/tdt_ctc-110m-q8_0.gguf \
  /tmp/parakeet_probe/speech.wav <simulator-udid>

PASS  loaded the model
PASS  transcribed
TEXT: Well, I don't wish to see it any more, observed Phoebe, turning away her
      eyes. It is certainly very like the old portrait.
parakeet check passed
```

Both the simulator and device (`PARAKEET_GGML_METAL=ON`, `-destination
generic/platform=iphoneos`) builds succeed. parakeet.cpp is iOS-viable in a way
libmosh was not: no `fork`/`exec`, no PTY, and the C API takes in-memory float
PCM, so no WAV file has to be written to transcribe a recording.

Version tested: parakeet.cpp `9edf17c` (2026-06-02), ggml submodule `e705c5f`,
model `tdt_ctc-110m-q8_0.gguf` (169.6 MB, SHA-256
`614feee3a990cf0e672b0314f4da0c80ae8da9094507f5ccb7c42e43b5fc5a12`), from
`mudler/parakeet-cpp-gguf`.

## The blocker

The app already links whisper.cpp with its **own static ggml** (`Vendor/whisper/`,
ggml 0.26.0). parakeet.cpp carries a **different, patched ggml** as a submodule
(`e705c5f` + three conv-2d/broadcast patches). Measured overlap between the two:

| archive | shared global symbols |
|---|---:|
| `libggml-base.a` | 910 |
| `libggml-cpu.a` | 533 |
| `libggml.a` | 44 |

Linking both is **not a link error**. A static archive only contributes symbols
that are still undefined, so the second ggml is skipped and whichever engine
lost silently binds to the other's ggml. That is worse than a failure: it
produces a binary that builds, loads both models, and returns a wrong answer
from one engine or crashes inside ggml with the pointer types not matching. A
test linking both for the simulator exited 0.

The layouts are **not** interchangeable: `ggml_tensor` is 336 bytes in both, but
`ggml.h` differs by 255 lines, and the Metal/CPU backends are the wrong versions
for each other.

### The three ways out

1. **One ggml, two engines.** Point whisper.cpp at ggml `e705c5f` and apply
   parakeet's three patches to it. Removes the duplicate; couples both engines
   to one ggml revision, so upgrading either means re-verifying both against the
   same table above.
2. **Build parakeet's symbols with a prefix.** `objcopy --prefix-symbols` (or
   the equivalent for the Mach-O/ld64 path) renames its ggml, leaving two
   coexist. Mechanical, but every future rebuild has to redo it, and a missed
   symbol fails at runtime rather than at link time.
3. **Split the app into extensions.** Each engine in its own process, real OS
   isolation, no symbol games. The heaviest option and the one that changes
   architecture rather than build flags.

### A fork to avoid

An earlier attempt tried `objcopy --redefine-syms` over the literal symbol names
in `src/`, and two sources both define `struct ggml_tensor` differently — a
fork that breaks on the next upstream bump and needs the same work redone.

## What is deliberately not here

`Vendor/parakeet/` is not populated in the repo. The archives are ~2.8 MB of
vendored binary and only make sense once one of the three options above is
chosen; committing them now would ship a ggml that the app cannot link. The
build script reproduces them in a couple of minutes.

## Two traps worth keeping

- **The Metal switch is `PARAKEET_GGML_METAL`, not `GGML_METAL`.** parakeet.cpp
  `FORCE`s the ggml option from its own variable, so setting `GGML_METAL=ON`
  directly is silently overwritten and the build comes out CPU-only with no
  warning. Caught only because the archive's symbol count was checked.
- **The simulator's GPU is a stub.** As with whisper (see
  `scripts/whisper-ios/README.md`), Metal here reports
  `recommendedMaxWorkingSetSize 0.00 MB` and traps — so `check.sh` runs with
  `PARAKEET_DEVICE=cpu`. The same source passes with the GPU on real hardware.