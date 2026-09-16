#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Compile one UTF-8 C source string directly to an x86_64 Windows PE64 file.
/// The backend is arm64 iOS code; TinyCC's compile-time target is x86_64 PE.
/// Returns 0 on success and a non-zero process-style status on failure.
int32_t xtool_windows_tcc_compile_string(
    const char *source_utf8,
    const char *output_path_utf8
);

/// Human-readable backend build/version string.
const char *xtool_windows_tcc_version(void);

/// Target produced by this backend.
const char *xtool_windows_tcc_target(void);

#ifdef __cplusplus
}
#endif
