/*
 * Implementation of the C seam declared in whisper_shim.h. The codec itself
 * lives in Vendor/whisper/libwhisper.a and the ggml archives beside it — this
 * file only marshals, because compiling whisper.cpp needs its own source tree
 * and scripts/whisper-ios/ is what has it.
 *
 * Segment text is copied into a single owned buffer rather than returned as
 * whisper.cpp's pointers. The library reuses its string storage between calls,
 * and a Swift caller holding a pointer across a transcribe would be reading
 * freed memory at exactly the moment it looked correct.
 */
#include "whisper_shim.h"
#include "whisper.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The catalog. Quotas are real: a quantised model is the difference between a
 * 488 MB download and a 190 MB one for a few percent of accuracy, which is the
 * trade a phone makes. Sizes and hashes are from the upstream HuggingFace repo
 * (ggerganov/whisper.cpp); the hashes are checked before a download is handed
 * to the model loader, because a truncated download otherwise loads as a
 * "corrupt model" with no clue which file was wrong. */
static const cqut_whisper_model kModels[] = {
    {"ggml-tiny.en.bin",           "Tiny (English)",           77704715,  0},
    {"ggml-tiny.en-q5_1.bin",      "Tiny (English, compact)",  32166155,  0},
    {"ggml-base.en.bin",           "Base (English)",          147964211,  0},
    {"ggml-small.en-q5_1.bin",     "Small (English, compact)", 190098681, 0},
    {"ggml-small.en.bin",          "Small (English)",         487614201,  0},
    {"ggml-tiny.bin",              "Tiny (multilingual)",      77691713,  1},
    {"ggml-base.bin",              "Base (multilingual)",     147951465,  1},
    {"ggml-small-q5_1.bin",        "Small (multilingual, compact)", 190085487, 1},
    {"ggml-small.bin",             "Small (multilingual)",    487601967,  1},
    {"ggml-large-v3-turbo-q5_0.bin", "Large v3 Turbo (compact)", 574041195, 1},
};

static const int kModelCount = (int)(sizeof(kModels) / sizeof(kModels[0]));
static const char *kBaseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

static const char *kSHA[] = {
    "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
    "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b",
    "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
    "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30",
    "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
    "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
    "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
    "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
    "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
    "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
};

static char g_error[512];

static void set_error(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(g_error, sizeof(g_error), fmt, args);
    va_end(args);
}

struct cqut_whisper {
    struct whisper_context *ctx;
    /* Rebuilt per transcription. whisper.cpp hands back pointers into its own
     * state; copying the text out here once keeps every later read safe. */
    char *text;
    size_t text_len;
    size_t *offsets;
    long long *starts_ms;
    long long *ends_ms;
    int segments;
};

cqut_whisper *cqut_whisper_load(const char *path, int use_gpu) {
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

    struct whisper_context_params params = whisper_context_default_params();
    /* Log spam is the library's, and it goes to stderr where it is noise in a
     * phone's console and, worse, a partial transcript that looks like ours. */
    params.use_gpu = use_gpu != 0;

    struct whisper_context *ctx = whisper_init_from_file_with_params(path, params);
    if (ctx == NULL) {
        set_error("not a whisper model: %s", path);
        return NULL;
    }

    cqut_whisper *handle = calloc(1, sizeof(cqut_whisper));
    if (handle == NULL) {
        whisper_free(ctx);
        set_error("out of memory");
        return NULL;
    }
    handle->ctx = ctx;
    return handle;
}

void cqut_whisper_free(cqut_whisper *handle) {
    if (handle == NULL) return;
    whisper_free(handle->ctx);
    free(handle->text);
    free(handle->offsets);
    free(handle->starts_ms);
    free(handle->ends_ms);
    free(handle);
}

int cqut_whisper_transcribe(cqut_whisper *handle, const float *samples, int n_samples,
                            const char *language) {
    g_error[0] = '\0';
    if (handle == NULL) {
        set_error("no model loaded");
        return -1;
    }
    if (samples == NULL || n_samples <= 0) {
        set_error("no audio");
        return -1;
    }

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    /* Every one of these is a print_* defaulting to on. In a CLI that is a
     * progress display; here it is stderr traffic per token, on a phone. */
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = false;
    params.no_context = true;
    params.n_threads = 4;
    /* Single segment, and this one matters.
     *
     * Whisper decodes in 30-second windows and, in long-form mode, can run a
     * second segment after the first — which on a clean 11-second clip meant
     * it emitted the last clause a second time ("…for your country. ask what
     * you can do for your country."). Dictation is not long-form: it is one
     * utterance, one command, well under a window, and the second segment is
     * never wanted. Forcing one segment removes the place the repeat came
     * from rather than trying to detect it afterwards.
     *
     * Temperature 0 with the fallback increments left in place, so a segment
     * that does go wrong is still retried hotter the way whisper.cpp intends. */
    params.single_segment = true;
    params.temperature = 0.0f;
    params.temperature_inc = 0.2f;
    if (language != NULL && *language != '\0' && strcmp(language, "auto") != 0) {
        params.language = language;
    }

    int rc = whisper_full(handle->ctx, params, samples, n_samples);
    if (rc != 0) {
        /* -6 is the library's "the GPU backend failed" code, and it is worth
         * its own message: on the simulator the Metal path traps rather than
         * returning, but on a device with a driver problem it does not, and
         * "could not transcribe" would send someone looking in the wrong
         * place. */
        if (rc == -6) {
            set_error("the GPU backend failed; try turning the GPU off in settings");
        } else {
            set_error("transcription failed (code %d)", rc);
        }
        return -1;
    }

    int n = whisper_full_n_segments(handle->ctx);
    free(handle->text);
    free(handle->offsets);
    free(handle->starts_ms);
    free(handle->ends_ms);
    handle->text = NULL;
    handle->offsets = NULL;
    handle->starts_ms = NULL;
    handle->ends_ms = NULL;
    handle->segments = 0;

    size_t slots = (size_t)(n > 0 ? n : 1);
    size_t total = 1;
    for (int i = 0; i < n; i++) {
        const char *piece = whisper_full_get_segment_text(handle->ctx, i);
        if (piece != NULL) total += strlen(piece);
    }
    handle->text = malloc(total);
    handle->offsets = malloc(sizeof(size_t) * slots);
    handle->starts_ms = malloc(sizeof(long long) * slots);
    handle->ends_ms = malloc(sizeof(long long) * slots);
    if (handle->text == NULL || handle->offsets == NULL
        || handle->starts_ms == NULL || handle->ends_ms == NULL) {
        set_error("out of memory");
        free(handle->text);
        free(handle->offsets);
        free(handle->starts_ms);
        free(handle->ends_ms);
        handle->text = NULL;
        handle->offsets = NULL;
        handle->starts_ms = NULL;
        handle->ends_ms = NULL;
        return -1;
    }

    handle->text[0] = '\0';
    handle->text_len = 0;
    for (int i = 0; i < n; i++) {
        const char *piece = whisper_full_get_segment_text(handle->ctx, i);
        if (piece == NULL) piece = "";
        handle->offsets[i] = handle->text_len;
        size_t len = strlen(piece);
        memcpy(handle->text + handle->text_len, piece, len);
        handle->text_len += len;
        handle->text[handle->text_len] = '\0';
        /* whisper.cpp reports centiseconds. */
        handle->starts_ms[i] = whisper_full_get_segment_t0(handle->ctx, i) * 10;
        handle->ends_ms[i] = whisper_full_get_segment_t1(handle->ctx, i) * 10;
    }
    handle->segments = n;
    return 0;
}

int cqut_whisper_segment_count(cqut_whisper *handle) {
    return handle == NULL ? 0 : handle->segments;
}

const char *cqut_whisper_segment_text(cqut_whisper *handle, int index) {
    if (handle == NULL || handle->text == NULL || handle->offsets == NULL
        || index < 0 || index >= handle->segments) {
        return NULL;
    }
    return handle->text + handle->offsets[index];
}

long long cqut_whisper_segment_start_ms(cqut_whisper *handle, int index) {
    if (handle == NULL || index < 0 || index >= handle->segments) return 0;
    return handle->starts_ms[index];
}

long long cqut_whisper_segment_end_ms(cqut_whisper *handle, int index) {
    if (handle == NULL || index < 0 || index >= handle->segments) return 0;
    return handle->ends_ms[index];
}

int cqut_whisper_gpu_available(void) {
    size_t count = ggml_backend_dev_count();
    for (size_t i = 0; i < count; i++) {
        enum ggml_backend_dev_type kind = ggml_backend_dev_type(ggml_backend_dev_get(i));
        if (kind == GGML_BACKEND_DEVICE_TYPE_GPU || kind == GGML_BACKEND_DEVICE_TYPE_IGPU) {
            return 1;
        }
    }
    return 0;
}

const char *cqut_whisper_last_error(void) {
    return g_error;
}

int cqut_whisper_models(cqut_whisper_model *out, int max) {
    int n = kModelCount;
    if (out != NULL) {
        for (int i = 0; i < n && i < max; i++) out[i] = kModels[i];
    }
    return n;
}

const char *cqut_whisper_model_url(const char *name) {
    if (name == NULL) return NULL;
    for (int i = 0; i < kModelCount; i++) {
        if (strcmp(kModels[i].name, name) == 0) {
            /* Assembled once per name into a static buffer, so the caller gets
             * a complete URL it can hand to URLSession directly. The table
             * holds only the file names; keeping a second full-URL string for
             * each would be ten strings to keep in step instead of five. */
            static char url[256];
            snprintf(url, sizeof(url), "%s%s", kBaseURL, kModels[i].name);
            return url;
        }
    }
    return NULL;
}

const char *cqut_whisper_model_sha256(const char *name) {
    if (name == NULL) return NULL;
    for (int i = 0; i < kModelCount; i++) {
        if (strcmp(kModels[i].name, name) == 0) return kSHA[i];
    }
    return NULL;
}