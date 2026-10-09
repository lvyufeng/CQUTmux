/*
 * A small C surface over whisper.cpp, for use from Swift.
 *
 * whisper.h would be importable directly, but not usefully: the interesting
 * types are `struct whisper_context` and `struct whisper_state` with their
 * fields in the open, the sampler is a function-pointer table filled in by the
 * caller, and the parameters struct has a different layout in almost every
 * release. Wrapping each of those in a C function keeps one stable seam
 * between the app and whatever version is vendored, and keeps the app from
 * having to reproduce whisper.cpp's struct layout in Swift.
 *
 * The model is not bundled. Whisper models run from 75 MB (tiny.en) to 3 GB
 * (large), so they are downloaded into the app container on demand, which is
 * also what Moshi does — "a model you download", removable later to reclaim
 * space. See scripts/whisper-ios/fetch-model.sh.
 *
 * GPU note: use_gpu is passed through rather than inferred. The Metal backend
 * builds and registers on the iOS simulator, and reports a real device, but
 * its working-set limit is 0 and it traps on the first graph. The app disables
 * the GPU there and keeps it on device.
 */
#ifndef CQUTMUX_WHISPER_SHIM_H
#define CQUTMUX_WHISPER_SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cqut_whisper cqut_whisper;

/* How a model binary is expected to describe itself, so the picker can tell
 * tiny from large before downloading 3 GB. */
typedef struct {
    const char *name;      /* "ggml-small.en.bin" */
    const char *label;     /* "Small (English)" */
    long long   bytes;     /* approximate download size */
    int         multilingual;
} cqut_whisper_model;

/* Loads a model from disk. Returns NULL if the file is missing or not a
 * whisper model; cqut_whisper_last_error says which. */
cqut_whisper *cqut_whisper_load(const char *path, int use_gpu);
void cqut_whisper_free(cqut_whisper *ctx);

/* Transcribes 16 kHz mono float samples. `language` may be NULL or "auto" for
 * detection; it is ignored by the .en models, which have only one language.
 * Returns 0 on success. */
int cqut_whisper_transcribe(cqut_whisper *ctx, const float *samples, int n_samples,
                            const char *language);

/* The text of segment `index`, or NULL when index is out of range. Valid until
 * the next transcribe call or free. */
const char *cqut_whisper_segment_text(cqut_whisper *ctx, int index);
int cqut_whisper_segment_count(cqut_whisper *ctx);

/* Milliseconds since the epoch when the segment started, and its length in
 * milliseconds. Both are 0 when the index is out of range. Used to line the
 * transcript up with the waveform, so a user can see which words the model
 * was unsure of. */
long long cqut_whisper_segment_start_ms(cqut_whisper *ctx, int index);
long long cqut_whisper_segment_end_ms(cqut_whisper *ctx, int index);

/* True when the vendored build can use the GPU at all (Metal present and a
 * device chosen). Not the same as "the GPU works here" — see the header note. */
int cqut_whisper_gpu_available(void);

const char *cqut_whisper_last_error(void);

/* The models the app offers, smallest first. Writes at most `max` entries and
 * returns how many there are in total. */
int cqut_whisper_models(cqut_whisper_model *out, int max);

/* URL to download `name` from, or NULL if it is not a known model. */
const char *cqut_whisper_model_url(const char *name);

/* Expected SHA-256 of `name`, so a download can be verified before a 3 GB
 * file is handed to the model loader. NULL if unknown. */
const char *cqut_whisper_model_sha256(const char *name);

/* ---------------------------------------------------------------------------
 * Parakeet
 *
 * A second engine behind the same seam, for the same reason. whisper.cpp 1.9.5
 * ships Parakeet in-tree (src/parakeet.cpp) and builds it against the *same*
 * ggml, so both engines arrive in the one vendored archive set. That detail is
 * the whole reason this is here: parakeet.cpp, the standalone project, carries
 * its own patched ggml, and two static ggmls in one binary do not fail to link
 * — the second is silently dropped and whichever engine lost binds to the
 * other's ggml. Sharing the build is what makes two engines possible at all.
 *
 * Moshi recommends Parakeet for English and many European languages, and the
 * reason is size: 0.6 B parameters here against whisper's multilingual models,
 * with nothing sent off the device.
 * ------------------------------------------------------------------------ */

typedef struct cqut_parakeet cqut_parakeet;

/* Loads a model from disk. Returns NULL if the file is missing or is not a
 * Parakeet model; cqut_parakeet_last_error says which. */
cqut_parakeet *cqut_parakeet_load(const char *path, int use_gpu);
void cqut_parakeet_free(cqut_parakeet *ctx);

/* Transcribes 16 kHz mono float samples. Returns 0 on success. Parakeet is
 * English-and-European only and decodes no language token, so there is no
 * `language` here — the engine selector in the app is what handles the choice,
 * not a parameter. */
int cqut_parakeet_transcribe(cqut_parakeet *ctx, const float *samples, int n_samples);

/* As cqut_whisper_segment_text and friends. Parakeet emits a single segment
 * covering the utterance, with word timing available per token. */
const char *cqut_parakeet_segment_text(cqut_parakeet *ctx, int index);
int cqut_parakeet_segment_count(cqut_parakeet *ctx);
long long cqut_parakeet_segment_start_ms(cqut_parakeet *ctx, int index);
long long cqut_parakeet_segment_end_ms(cqut_parakeet *ctx, int index);
int cqut_parakeet_token_count(cqut_parakeet *ctx, int segment);

const char *cqut_parakeet_last_error(void);

/* True when the vendored build has Parakeet compiled in. The app asks before
 * offering the engine, so a build without it hides the option instead of
 * failing when a user taps the microphone. */
int cqut_parakeet_available(void);

/* The Parakeet models the app offers. Same contract as cqut_whisper_models. */
int cqut_parakeet_models(cqut_whisper_model *out, int max);
const char *cqut_parakeet_model_url(const char *name);
const char *cqut_parakeet_model_sha256(const char *name);

#ifdef __cplusplus
}
#endif

#endif /* CQUTMUX_WHISPER_SHIM_H */
