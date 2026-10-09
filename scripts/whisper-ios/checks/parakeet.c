/*
 * Feeds a WAV through Parakeet, through *our* seam rather than the CLI's.
 *
 * The distinction matters. parakeet-cli links parakeet.cpp directly; the app
 * goes through cqut_parakeet_*, which copies segment text out of the library's
 * storage and converts segment timing. A bug in either of those produces a
 * transcript that looks plausible and timings that are wrong by 10x, and the
 * CLI would show neither.
 *
 * It also checks the thing that makes two engines possible: both archives are
 * linked here exactly as the app links them, from one ggml, and the check
 * asserts Parakeet's words rather than merely that something returned.
 *
 * The timing assertion is separate from the transcript one because the units
 * were wrong the first time and nothing else would have said so. parakeet.cpp
 * reports frames (100 per second) where whisper reports centiseconds; both
 * numbers look plausible, and a 10x error in a timestamp no words can reveal.
 * So the end of the last segment is compared against the length of the audio.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "whisper_shim.h"

/* The same chunk-walking reader the whisper check uses, for the same reason:
 * a fixed 44-byte header offset reads the LIST chunk as samples. */
static float *read_wav(const char *path, int *n_samples) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return NULL; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *raw = malloc(size);
    if (fread(raw, 1, size, f) != (size_t)size) { fclose(f); free(raw); return NULL; }
    fclose(f);

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
    if (argc < 3) { fprintf(stderr, "usage: parakeet <model> <wav> [expect...]\n"); return 2; }

    if (!cqut_parakeet_available()) {
        printf("PARAKEET_CHECK_FAIL the vendored build has no Parakeet\n");
        return 1;
    }

    const char *no_gpu = getenv("WHISPER_NO_GPU");
    cqut_parakeet *ctx = cqut_parakeet_load(argv[1], !(no_gpu && *no_gpu));
    if (!ctx) {
        printf("PARAKEET_CHECK_FAIL load: %s\n", cqut_parakeet_last_error());
        return 1;
    }

    int n_samples = 0;
    float *samples = read_wav(argv[2], &n_samples);
    if (!samples) { printf("PARAKEET_CHECK_FAIL could not read %s\n", argv[2]); return 1; }
    printf("audio: %d samples (%.1f s)\n", n_samples, (double)n_samples / 16000.0);

    if (cqut_parakeet_transcribe(ctx, samples, n_samples) != 0) {
        printf("PARAKEET_CHECK_FAIL transcribe: %s\n", cqut_parakeet_last_error());
        return 1;
    }

    int n = cqut_parakeet_segment_count(ctx);
    printf("segments: %d\n", n);
    if (n <= 0) { printf("PARAKEET_CHECK_FAIL no segments\n"); return 1; }

    char text[4096];
    text[0] = '\0';
    for (int i = 0; i < n; i++) {
        const char *piece = cqut_parakeet_segment_text(ctx, i);
        if (piece) strncat(text, piece, sizeof(text) - strlen(text) - 1);
        printf("  [%d] %lld..%lld ms  %d tokens  \"%s\"\n", i,
               cqut_parakeet_segment_start_ms(ctx, i),
               cqut_parakeet_segment_end_ms(ctx, i),
               cqut_parakeet_token_count(ctx, i),
               piece ? piece : "");
    }
    printf("TEXT: %s\n", text);

    int failures = 0;
    for (int i = 3; i < argc; i++) {
        if (strcasestr(text, argv[i])) {
            printf("PASS  transcript contains \"%s\"\n", argv[i]);
        } else {
            printf("FAIL  transcript is missing \"%s\"\n", argv[i]);
            failures++;
        }
    }

    /* The timing unit, asserted rather than assumed. An 11-second clip whose
     * end is reported as ~11_000 is milliseconds; 1_100 would be centiseconds
     * — the same number whisper would have produced for the same audio. */
    long long end_ms = cqut_parakeet_segment_end_ms(ctx, n - 1);
    double audio_ms = 1000.0 * n_samples / 16000.0;
    if (end_ms > audio_ms * 0.5 && end_ms <= audio_ms * 1.5) {
        printf("PASS  segment timing is milliseconds (end %lld vs audio %.0f)\n", end_ms, audio_ms);
    } else {
        printf("FAIL  segment timing looks off: end %lld for %.0f ms of audio\n", end_ms, audio_ms);
        failures++;
    }

    free(samples);
    cqut_parakeet_free(ctx);
    printf("\n%s\n", failures == 0 ? "PARAKEET_CHECK_PASS" : "PARAKEET_CHECK_FAIL");
    return failures == 0 ? 0 : 1;
}
