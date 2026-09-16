#include "XToolWindowsTCC.h"
#include "libtcc.h"

#include <stdio.h>

#ifndef XTOOL_WINDOWS_TCC_VERSION
#define XTOOL_WINDOWS_TCC_VERSION "tinycc-0fb54300-x86_64-pe"
#endif

static void xtool_tcc_error(void *opaque, const char *message) {
    (void)opaque;
    if (message && *message) {
        fprintf(stderr, "xtool-windows-tcc: %s\n", message);
    }
}

int32_t xtool_windows_tcc_compile_string(
    const char *source_utf8,
    const char *output_path_utf8
) {
    if (!source_utf8 || !output_path_utf8 || !*output_path_utf8) {
        return 64;
    }

    TCCState *state = tcc_new();
    if (!state) {
        fprintf(stderr, "xtool-windows-tcc: tcc_new failed\n");
        return 70;
    }

    tcc_set_error_func(state, NULL, xtool_tcc_error);

    /*
     * Phase 20 bootstrap intentionally has no Windows CRT dependency.
     * `main` is the PE entry point so a tiny program such as
     * `int main(void) { return 42; }` stays self-contained.
     *
     * Set -nostdlib before the output type because libtcc otherwise tries to
     * add target CRT objects while configuring executable output.
     */
    if (tcc_set_options(state, "-nostdlib -Wl,-e,main") < 0) {
        tcc_delete(state);
        return 1;
    }

    if (tcc_set_output_type(state, TCC_OUTPUT_EXE) < 0) {
        tcc_delete(state);
        return 1;
    }

    if (tcc_compile_string(state, source_utf8) < 0) {
        tcc_delete(state);
        return 1;
    }

    if (tcc_output_file(state, output_path_utf8) < 0) {
        tcc_delete(state);
        return 1;
    }

    tcc_delete(state);
    return 0;
}

const char *xtool_windows_tcc_version(void) {
    return XTOOL_WINDOWS_TCC_VERSION;
}

const char *xtool_windows_tcc_target(void) {
    return "x86_64-pc-windows-pe64";
}
