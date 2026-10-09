# Parakeet on iOS

Parakeet ships, and it turned out to need no separate build at all.

Moshi describes four speech engines and calls Parakeet its current
recommendation for English — *"the best balance of speed and accuracy for those
languages"*. We had two. The gap was closed by finding that **whisper.cpp 1.9.5
ships Parakeet in-tree** (`src/parakeet.cpp`, `include/parakeet.h`, its own
`parakeet` target) built against **the same ggml**. It arrives in the archive set
`scripts/whisper-ios/build.sh` already produces. There is nothing in this
directory to build, and no `Vendor/parakeet/`.

## Why the standalone project is not used

`rjyo/parakeet.cpp` carries its own **patched ggml** as a submodule. Linking it
alongside whisper's static ggml is not a link error: a static archive only
contributes symbols that are still undefined, so the second ggml is silently
dropped and whichever engine lost binds to the other's. Measured overlap was 910
shared symbols in `libggml-base.a` alone, and a test binary linking both exited
0 — a build that succeeds, loads both models, and is wrong.

It was never necessary. The in-tree Parakeet is the same engine on the same ggml,
so there is one copy of everything.

## What is verified

Through our own seam (not the CLI), on the simulator, asserting the words:

```
CQUT_ENGINE=parakeet WHISPER_NO_GPU=1 WHISPER_SAMPLE=…/speech.wav \
  scripts/whisper-ios/check.sh Vendor/whisper …/ggml-parakeet-tdt-0.6b-v3-q8_0.bin

PASS  transcript contains "Phoebe"
PASS  transcript contains "portrait"
PASS  segment timing is milliseconds (end 7440 vs audio 7435)
PARAKEET_CHECK_PASS
```

And at app level, through the same code path the microphone takes:

```
CQUT_ENGINE=parakeet CQUT_MODEL_NAME=ggml-parakeet-tdt-0.6b-v3-q8_0.bin \
  scripts/whisper-ios/app-test.sh …/pk-q8.bin …/speech.wav

TRANSCRIBE_OK
Well, I don't wish to see it any more, observed Phoebe, turning away her eyes.
It is certainly very like the old portrait.
==> PASS: the app loaded a parakeet model and recognised the recording
```

Whisper is regression-checked the same way on the same build, because both
engines now link the one ggml and a change to it can only be safe if both still
work.

## The trap worth remembering

**parakeet.cpp reports segment time in frames, not milliseconds** — 100 frames
per second, so numerically identical to the centiseconds whisper.cpp reports for
the same field. The first version of the seam passed the raw number through
under a comment claiming milliseconds. A 7.4-second clip came back with an end
time of 744, which reads as a plausible sub-second timestamp rather than as
being off by 10×, and no transcript comparison would ever have caught it. The
check now asserts the unit against the length of the audio, which is the only
thing that can.

## Models

`ggml-org/parakeet-GGUF`, in the GGML format whisper.cpp's loader expects —
note that `parakeet.cpp`'s own GGUF files are **not** readable here, and vice
versa. Sizes and SHA-256s are in `scripts/whisper-ios/driver/parakeet_shim.c`.