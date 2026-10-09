// Checks parakeet.cpp's transcription against a known recording.
//
// Written because the build succeeding proves nothing about the model: a
// mismatched ggml, an unapplied patch, or a decoder wired to the wrong head all
// produce a binary that loads a GGUF happily and then emits nonsense. The only
// evidence worth having is the words.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "parakeet_capi.h"

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: transcribe <model.gguf> <audio.wav> [expect...]\n");
        return 2;
    }
    const char *model = argv[1];
    const char *wav = argv[2];

    printf("abi=%d\n", parakeet_capi_abi_version());

    parakeet_ctx *ctx = parakeet_capi_load(model);
    if (!ctx) {
        printf("FAIL  could not load %s\n", model);
        return 1;
    }
    printf("PASS  loaded the model\n");

    char *text = parakeet_capi_transcribe_path(ctx, wav, 0);
    if (!text) {
        printf("FAIL  transcribe returned nothing: %s\n", parakeet_capi_last_error(ctx));
        parakeet_capi_free(ctx);
        return 1;
    }
    printf("PASS  transcribed\n");
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

    parakeet_capi_free_string(text);
    parakeet_capi_free(ctx);
    printf("\n%s\n", failures == 0 ? "parakeet check passed" : "parakeet check FAILED");
    return failures == 0 ? 0 : 1;
}