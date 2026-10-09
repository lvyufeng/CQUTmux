# whisper.cpp on iOS

On-device speech-to-text, vendored the same way `scripts/et-ios/` vendors
Eternal Terminal: cross-compile the upstream source into static archives, keep
one small C driver as the seam, and let SwiftPM ship only the header.

## What is here

| File | What it does |
|---|---|
| `build.sh` | Cross-compiles whisper.cpp + ggml into `Vendor/whisper/` |
| `driver/whisper_shim.c` | The C seam: load, transcribe, read segments |
| `check.sh` | Codec-level check — archives linked directly, `jfk.wav` in, text out |
| `app-test.sh` | App-level check — the same recording through the shipped app |
| `model.sh` | Fetches a model for the scripts to use |

## Build

    PATH="$HOME/.local/bin:$PATH" scripts/whisper-ios/build.sh <whisper-src> Vendor/whisper simulator
    PATH="$HOME/.local/bin:$PATH" scripts/whisper-ios/build.sh <whisper-src> Vendor/whisper device

`cmake` is not on PATH on this machine and is not installable via brew; it is
available as `python3 -m cmake`, and `~/.local/bin/cmake` is a two-line shim:

    #!/bin/sh
    exec python3 -m cmake "$@"

## Testing

    scripts/whisper-ios/model.sh                      # fetches ggml-tiny.en.bin
    scripts/whisper-ios/check.sh Vendor/whisper /tmp/whisper-models/ggml-tiny.en.bin
    scripts/whisper-ios/app-test.sh

`check.sh` needs a booted **iOS** simulator. It picks the first booted device,
which on this machine is sometimes the Apple Watch one — pass the iPhone's udid
explicitly if the run aborts inside `dyld`.

## The two checks are not redundant

`check.sh` links the archives directly and proves the codec works. `app-test.sh`
proves the *app* works: the model catalog and the path it looks in, the SwiftPM
C seam, `WhisperDictation`'s decoding and model load, and the link flags on the
app target. A model that loads in a harness and not in the app is a real failure
mode, and only the second check would catch it.

## Three things worth knowing

**Size.** The upstream `build-xcframework.sh` builds iOS device, macOS,
visionOS and tvOS and makes a *dynamic* framework. This app runs on iOS, links
statically, and needs one platform at a time — so `build.sh` drives the same
CMake configure for the slice it was asked for and keeps the six static
archives. `GGML_METAL_EMBED_LIBRARY=ON` is the upstream setting worth keeping:
it compiles the Metal shader source into the archive, so the app ships no
`.metal` file and compiles nothing at launch.

**The simulator's GPU does not work.** Its Metal device registers, compiles the
kernel library, and then traps on the first graph — it reports
`recommendedMaxWorkingSetSize = 0.00 MB`. The same source and the same flags
built for macOS run the Metal path correctly (verified against Apple M4), so
this is the simulator, not the build. The app therefore passes `use_gpu = false`
under `#if targetEnvironment(simulator)`, and `check.sh` has a
`WHISPER_NO_GPU=1` switch for the same reason. On device the GPU is used.

**Single segment, not long-form.** Whisper decodes in 30-second windows and in
long-form mode can emit a second segment. On an 11-second clip that produced
the last clause twice. Dictation is one utterance, well under a window, so the
shim sets `single_segment` — removing the place the repeat came from rather
than trying to detect it afterwards.

## Why the models are not in the repository

They run from 32 MB to 574 MB, and there are ten of them. The app downloads the
one the user picks (`WhisperModelStore`), verifies its SHA-256 against the
catalog in `whisper_shim.c`, and can delete it again. `model.sh` exists so the
scripts have a file before the app has ever run.

## Versions

- whisper.cpp `d1be6fd` ("bump version to 1.9.5"), ggml 0.26.0
- Built with Xcode 27, deployment target iOS 18.0, arm64
- Backends: Metal (device), BLAS via Accelerate, and CPU