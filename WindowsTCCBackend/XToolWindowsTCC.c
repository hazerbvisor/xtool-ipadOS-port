#include "XToolWindowsTCC.h"
#include "libtcc.h"

#include <stdio.h>
#include <string.h>

#ifndef XTOOL_WINDOWS_TCC_VERSION
#define XTOOL_WINDOWS_TCC_VERSION "tinycc-0fb54300-x86_64-pe"
#endif

static char xtool_tcc_last_error_text[2048];

static void xtool_tcc_reset_error(void) {
    xtool_tcc_last_error_text[0] = '\0';
}

static void xtool_tcc_set_error(const char *message) {
    if (!message || !*message) {
        return;
    }
    snprintf(
        xtool_tcc_last_error_text,
        sizeof xtool_tcc_last_error_text,
        "%s",
        message
    );
}

static void xtool_tcc_error(void *opaque, const char *message) {
    size_t used;
    (void)opaque;
    if (!message || !*message) {
        return;
    }

    used = strlen(xtool_tcc_last_error_text);
    if (used < sizeof xtool_tcc_last_error_text - 1) {
        snprintf(
            xtool_tcc_last_error_text + used,
            sizeof xtool_tcc_last_error_text - used,
            "%s%s",
            used ? "\n" : "",
            message
        );
    }
    fprintf(stderr, "xtool-windows-tcc: %s\n", message);
}

int32_t xtool_windows_tcc_compile_string(
    const char *source_utf8,
    const char *output_path_utf8
) {
    TCCState *state;

    xtool_tcc_reset_error();

    if (!source_utf8 || !output_path_utf8 || !*output_path_utf8) {
        xtool_tcc_set_error("invalid source or output path");
        return 64;
    }

    state = tcc_new();
    if (!state) {
        xtool_tcc_set_error("tcc_new failed");
        return 70;
    }

    tcc_set_error_func(state, NULL, xtool_tcc_error);

    /*
     * This first bootstrap is deliberately freestanding: no Windows SDK,
     * CRT, import libraries or libtcc1 are required. TinyCC's PE backend uses
     * `_start` as its natural executable entry symbol when no CRT is linked,
     * so the source defines `_start` directly instead of routing through
     * `main` with a linker entry override.
     *
     * -nostdlib must be applied before choosing TCC_OUTPUT_EXE because output
     * setup otherwise attempts to add target CRT support files.
     */
    if (tcc_set_options(state, "-nostdlib") < 0) {
        if (!xtool_tcc_last_error_text[0]) {
            xtool_tcc_set_error("TinyCC option setup failed (-nostdlib)");
        }
        tcc_delete(state);
        return 11;
    }

    if (tcc_set_output_type(state, TCC_OUTPUT_EXE) < 0) {
        if (!xtool_tcc_last_error_text[0]) {
            xtool_tcc_set_error("TinyCC executable output setup failed");
        }
        tcc_delete(state);
        return 12;
    }

    if (tcc_compile_string(state, source_utf8) < 0) {
        if (!xtool_tcc_last_error_text[0]) {
            xtool_tcc_set_error("TinyCC source compilation failed");
        }
        tcc_delete(state);
        return 13;
    }

    if (tcc_output_file(state, output_path_utf8) < 0) {
        if (!xtool_tcc_last_error_text[0]) {
            xtool_tcc_set_error("TinyCC PE64 output/link step failed");
        }
        tcc_delete(state);
        return 14;
    }

    tcc_delete(state);
    return 0;
}

const char *xtool_windows_tcc_last_error(void) {
    return xtool_tcc_last_error_text;
}

const char *xtool_windows_tcc_version(void) {
    return XTOOL_WINDOWS_TCC_VERSION;
}

const char *xtool_windows_tcc_target(void) {
    return "x86_64-pc-windows-pe64";
}
