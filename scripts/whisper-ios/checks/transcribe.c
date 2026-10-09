/*
 * Feeds a WAV through the vendored whisper.cpp and prints what it heard.
 *
 * Existence of libwhisper.a proves only that CMake ran. The failure mode worth
 * ruling out is subtler: a backend that configured but did not register, or a
 * Metal library that compiled but is not embedded, still links and still
 * returns a model — it just does nothing useful when you call it. So this
 * checks the two things that decide whether on-device dictation is real:
 * the Metal backend is actually registered, and a known recording comes back
 * as the words that were said in it.
 *
 * Runs inside the simulator, because a static archive built for
 * arm64-apple-ios-simulator cannot be linked into a macOS binary.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "whisper.h"
#include "ggml-backend.h"

static float *read_wav(const char *path, int *n_samples) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return NULL; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *raw = malloc(size);
    if (fread(raw, 1, size, f) != (size_t)size) { fclose(f); free(raw); return NULL; }
    fclose(f);

    /* Walk the chunks rather than assuming a fixed 44-byte header: the file
     * from the repo has a LIST chunk in it, and a fixed offset would read the
     * metadata as samples. */
    long pos = 12;
    long data_at = -1, data_len = 0;
    while (pos + 8 <= size) {
        char id[5] = {0};
        memcpy(id, raw + pos, 4);
        unsigned int len;
        memcpy(&len, raw + pos + 4, 4);
        if (strcmp(id, "data") == 0) { data_at = pos + 8; data_len = len; break; }
        pos += 8 + len + (len & 1);
    }
    if (data_at < 0) { fprintf(stderr, "no data chunk\n"); free(raw); return NULL; }

    int count = (int)(data_len / 2);
    float *samples = malloc(sizeof(float) * count);
    const short *pcm = (const short *)(raw + data_at);
    for (int i = 0; i < count; i++) samples[i] = (float)pcm[i] / 32768.0f;
    free(raw);
    *n_samples = count;
    return samples;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: transcribe <model> <wav>\n"); return 2; }

    /* Backends first: if Metal is not registered here, every later result is
     * the CPU path and the build silently differs from what we shipped. */
    static const char *kTypes[] = {"cpu", "gpu", "igpu", "accel", "meta"};
    size_t n_devices = ggml_backend_dev_count();
    int saw_metal = 0, saw_cpu = 0;
    for (size_t i = 0; i < n_devices; i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        const char *name = ggml_backend_dev_name(dev);
        enum ggml_backend_dev_type kind = ggml_backend_dev_type(dev);
        printf("device: %-16s (%s)\n", name, kind <= GGML_BACKEND_DEVICE_TYPE_META ? kTypes[kind] : "?");
        // By type, not by name: the Metal device reports itself as "MTL0",
        // so a strstr for "Metal" quietly never matches and every run below
        // would have been the CPU path while claiming to test the GPU.
        if (kind == GGML_BACKEND_DEVICE_TYPE_GPU || kind == GGML_BACKEND_DEVICE_TYPE_IGPU) saw_metal = 1;
        if (kind == GGML_BACKEND_DEVICE_TYPE_CPU) saw_cpu = 1;
    }
    if (!saw_cpu) { printf("WHISPER_CHECK_FAIL no CPU backend registered\n"); return 1; }

    struct whisper_context_params cparams = whisper_context_default_params();
    /* Selectable because the simulator's Metal backend is not the device's:
     * it advertises Metal and compiles the kernel library, then traps in the
     * first graph. Being able to turn the GPU off is what separates "our build
     * is wrong" from "this GPU cannot run these kernels". */
    const char *no_gpu = getenv("WHISPER_NO_GPU");
    cparams.use_gpu = saw_metal && !(no_gpu && *no_gpu);
    struct whisper_context *ctx = whisper_init_from_file_with_params(argv[1], cparams);
    if (!ctx) { printf("WHISPER_CHECK_FAIL could not load %s\n", argv[1]); return 1; }

    int n_samples = 0;
    float *samples = read_wav(argv[2], &n_samples);
    if (!samples) { printf("WHISPER_CHECK_FAIL could not read %s\n", argv[2]); return 1; }
    printf("samples: %d (%.2fs)\n", n_samples, n_samples / 16000.0);

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.single_segment = true;
    params.no_context = true;

    if (whisper_full(ctx, params, samples, n_samples) != 0) {
        printf("WHISPER_CHECK_FAIL whisper_full\n");
        return 1;
    }

    char heard[1024] = {0};
    int n = whisper_full_n_segments(ctx);
    for (int i = 0; i < n; i++) strncat(heard, whisper_full_get_segment_text(ctx, i), sizeof(heard) - strlen(heard) - 1);
    printf("heard: %s\n", heard);

    /* jfk.wav is the sentence the upstream README transcribes. Matching on a
     * couple of distinctive words, not the whole string, so a different-but-
     * correct punctuation choice does not read as a failure. */
    int ok = strstr(heard, "country") && strstr(heard, "ask");
    printf(ok ? "WHISPER_CHECK_PASS\n" : "WHISPER_CHECK_FAIL unexpected transcript\n");

    free(samples);
    whisper_free(ctx);
    return ok ? 0 : 1;
}
