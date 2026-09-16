#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Run the Windows-focused Clang cc1 frontend in-process.
/// argv contains cc1-style arguments with no argv[0] and no `-cc1` marker.
int32_t xtool_windows_clang_run(int32_t argc, const char *const *argv);

/// Run LLD's Windows COFF/PE driver in-process.
/// argv contains ordinary lld-link style arguments; the bridge supplies argv[0].
int32_t xtool_windows_lld_coff_run(int32_t argc, const char *const *argv);

/// Human-readable Windows backend build/version string.
const char *xtool_windows_backend_version(void);

#ifdef __cplusplus
}
#endif
