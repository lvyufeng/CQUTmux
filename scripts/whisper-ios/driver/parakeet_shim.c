/*
 * Parakeet behind the same seam as whisper, in one translation unit so both
 * engines share the model catalog type in whisper_shim.h.
 *
 * parakeet.h is used exactly as whisper.h is: the struct fields stay in the
 * library and the app only ever sees an opaque handle and copied text. The
 * copy matters for the same reason it does there — parakeet.cpp hands back
 * pointers into its own state, and a caller holding one across the next
 * transcribe would be reading memory the library has since reused.
 *
 * Segment timing is a deliberate difference from whisper. Parakeet reports one
 * segment for the whole utterance with the word-level timing on the tokens, so
 * start/end here describe the utterance rather than a sentence within it. The
 * app draws a single segment for Parakeet and a list for whisper; pretending
 * otherwise would mean inventing boundaries the model did not produce.
 */
#include "whisper_shim.h"
#include "parakeet.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Sizes and hashes from ggml-org/parakeet-GGUF. The hashes are checked before
 * a download is handed to the loader: a truncated file otherwise reports
 * "invalid model data (bad magic)" with no clue which download was at fault. */
static const cqut_whisper_model kModels[] = {
    {"ggml-parakeet-tdt-0.6b-v3-q4_k.bin", "Parakeet 0.6B (compact)",  415611879, 0},
    {"ggml-parakeet-tdt-0.6b-v3-q8_0.bin", "Parakeet 0.6B",            668757119, 0},
    {"ggml-parakeet-tdt-0.6b-v3-f16.bin",  "Parakeet 0.6B (full)",   1255897319, 0},
};

static const int kModelCount = (int)(sizeof(kModels) / sizeof(kModels[0]));
static const char *kBaseURL = "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/";

static const char *kSHA[] = {
    "8b205b8b39c6535e153de6fb11c51db46125d45c4f16ba496fe41a0fe71b885e",
    "4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e",
    "833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f",
};

static char g_error[512];

static void set_error(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(g_error, sizeof(g_error), fmt, args);
    va_end(args);
}

struct cqut_parakeet {
    struct parakeet_context *ctx;
    /* Copied out for the same reason whisper's is: the library reuses its
     * string storage between calls. */
    char *text;
    size_t text_len;
    size_t *offsets;
    long long *starts_ms;
    long long *ends_ms;
    int segments;
    int *tokens;
};

cqut_parakeet *cqut_parakeet_load(const char *path, int use_gpu) {
    g_error[0] = '\0';
    if (path == NULL) {
        set_error("no model path");
        return NULL;
    }

    FILE *probe = fopen(path, "rb");
    if (probe == NULL) {
        set_error("model file not found: %s", path);
        return NULL;
    }
    fclose(probe);

    struct parakeet_context_params params = parakeet_context_default_params();
    params.use_gpu = use_gpu != 0;

    struct parakeet_context *ctx = parakeet_init_from_file_with_params(path, params);
    if (ctx == NULL) {
        set_error("not a Parakeet model: %s", path);
        return NULL;
    }

    cqut_parakeet *handle = calloc(1, sizeof(cqut_parakeet));
    if (handle == NULL) {
        parakeet_free(ctx);
        set_error("out of memory");
        return NULL;
    }
    handle->ctx = ctx;
    return handle;
}

void cqut_parakeet_free(cqut_parakeet *handle) {
    if (handle == NULL) return;
    parakeet_free(handle->ctx);
    free(handle->text);
    free(handle->offsets);
    free(handle->starts_ms);
    free(handle->ends_ms);
    free(handle->tokens);
    free(handle);
}

int cqut_parakeet_transcribe(cqut_parakeet *handle, const float *samples, int n_samples) {
    g_error[0] = '\0';
    if (handle == NULL) {
        set_error("no model loaded");
        return -1;
    }
    if (samples == NULL || n_samples <= 0) {
        set_error("no audio");
        return -1;
    }

    struct parakeet_full_params params = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY);
    /* Fewer knobs than whisper's struct has, and no print_* set at all —
     * parakeet_full_params has none, so its logging is compile-time rather than
     * per-call. What is set here is what dictation needs: no context from
     * earlier transcriptions, and enough threads to not wait. */
    params.no_context = true;
    params.n_threads = 4;

    int rc = parakeet_full(handle->ctx, params, samples, n_samples);
    if (rc != 0) {
        set_error("transcription failed (code %d)", rc);
        return -1;
    }

    int n = parakeet_full_n_segments(handle->ctx);
    free(handle->text);
    free(handle->offsets);
    free(handle->starts_ms);
    free(handle->ends_ms);
    free(handle->tokens);
    handle->text = NULL;
    handle->offsets = NULL;
    handle->starts_ms = NULL;
    handle->ends_ms = NULL;
    handle->tokens = NULL;
    handle->segments = 0;

    size_t slots = (size_t)(n > 0 ? n : 1);
    size_t total = 1;
    for (int i = 0; i < n; i++) {
        const char *piece = parakeet_full_get_segment_text(handle->ctx, i);
        if (piece != NULL) total += strlen(piece);
    }
    handle->text = malloc(total);
    handle->offsets = malloc(sizeof(size_t) * slots);
    handle->starts_ms = malloc(sizeof(long long) * slots);
    handle->ends_ms = malloc(sizeof(long long) * slots);
    handle->tokens = malloc(sizeof(int) * slots);
    if (handle->text == NULL || handle->offsets == NULL
        || handle->starts_ms == NULL || handle->ends_ms == NULL || handle->tokens == NULL) {
        set_error("out of memory");
        free(handle->text); free(handle->offsets);
        free(handle->starts_ms); free(handle->ends_ms);
        free(handle->tokens);
        handle->text = NULL; handle->offsets = NULL;
        handle->starts_ms = NULL; handle->ends_ms = NULL; handle->tokens = NULL;
        return -1;
    }

    handle->text[0] = '\0';
    handle->text_len = 0;
    for (int i = 0; i < n; i++) {
        const char *piece = parakeet_full_get_segment_text(handle->ctx, i);
        if (piece == NULL) piece = "";
        handle->offsets[i] = handle->text_len;
        size_t len = strlen(piece);
        memcpy(handle->text + handle->text_len, piece, len);
        handle->text_len += len;
        handle->text[handle->text_len] = '\0';
        /* Frames, not milliseconds. parakeet.cpp sets a segment's t1 to
         * state->n_frames, and the encoder runs at 100 frames per second, so a
         * frame is 10 ms — the same numeric unit whisper.cpp reports for its
         * centiseconds, which is a coincidence worth not relying on. Converted
         * here so both engines hand the app milliseconds.
         *
         * This was wrong first time round, in the direction that is invisible:
         * a 7.4-second clip reported an end of 744, which reads as a plausible
         * sub-second timestamp rather than as being off by 10x. The check now
         * asserts the unit against the audio length. */
        handle->starts_ms[i] = (long long)parakeet_full_get_segment_t0(handle->ctx, i) * 10;
        handle->ends_ms[i] = (long long)parakeet_full_get_segment_t1(handle->ctx, i) * 10;
        handle->tokens[i] = parakeet_full_n_tokens(handle->ctx, i);
    }
    handle->segments = n;
    return 0;
}

int cqut_parakeet_segment_count(cqut_parakeet *handle) {
    return handle == NULL ? 0 : handle->segments;
}

const char *cqut_parakeet_segment_text(cqut_parakeet *handle, int index) {
    if (handle == NULL || handle->text == NULL || handle->offsets == NULL) return NULL;
    if (index < 0 || index >= handle->segments) return NULL;
    return handle->text + handle->offsets[index];
}

long long cqut_parakeet_segment_start_ms(cqut_parakeet *handle, int index) {
    if (handle == NULL || handle->starts_ms == NULL) return 0;
    if (index < 0 || index >= handle->segments) return 0;
    return handle->starts_ms[index];
}

long long cqut_parakeet_segment_end_ms(cqut_parakeet *handle, int index) {
    if (handle == NULL || handle->ends_ms == NULL) return 0;
    if (index < 0 || index >= handle->segments) return 0;
    return handle->ends_ms[index];
}

int cqut_parakeet_token_count(cqut_parakeet *handle, int segment) {
    if (handle == NULL || handle->tokens == NULL) return 0;
    if (segment < 0 || segment >= handle->segments) return 0;
    return handle->tokens[segment];
}

const char *cqut_parakeet_last_error(void) {
    return g_error;
}

int cqut_parakeet_available(void) {
    return 1;
}

int cqut_parakeet_models(cqut_whisper_model *out, int max) {
    int written = 0;
    for (int i = 0; i < kModelCount && written < max; i++) {
        out[written++] = kModels[i];
    }
    return kModelCount;
}

const char *cqut_parakeet_model_url(const char *name) {
    if (name == NULL) return NULL;
    for (int i = 0; i < kModelCount; i++) {
        if (strcmp(kModels[i].name, name) == 0) {
            static char url[512];
            snprintf(url, sizeof(url), "%s%s", kBaseURL, name);
            return url;
        }
    }
    return NULL;
}

const char *cqut_parakeet_model_sha256(const char *name) {
    if (name == NULL) return NULL;
    for (int i = 0; i < kModelCount; i++) {
        if (strcmp(kModels[i].name, name) == 0) return kSHA[i];
    }
    return NULL;
}
