/*
 * Deliberately empty translation unit.
 *
 * CQUTWhisperC is a pure header target: the module it exports is
 * whisper_shim.h, and the implementation it describes lives in
 * Vendor/whisper/<platform>/libwhisperclient.a (see scripts/whisper-ios/),
 * because compiling it needs whisper.h and ggml's headers, which are only
 * in that vendored tree. SwiftPM still wants at least one source file in a C
 * target — without this the link fails on a missing CQUTWhisperC.o.
 *
 * It must not define anything: the same symbols are already in the archive,
 * and a definition here would collide with them at link time.
 */
#include "whisper_shim.h"
