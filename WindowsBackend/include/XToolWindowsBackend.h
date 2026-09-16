#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Lower LLVM bitcode produced by the main XTool Clang frontend into an
/// x86_64 Windows COFF object.
/// argv[0] = input .bc path
/// argv[1] = output .obj path
/// argv[2] = optional target triple (defaults to x86_64-pc-windows-msvc)
int32_t xtool_windows_codegen_run(int32_t argc, const char *const *argv);

/// Run LLD's Windows COFF/PE driver in-process.
/// argv contains ordinary lld-link style arguments; the bridge supplies argv[0].
int32_t xtool_windows_lld_coff_run(int32_t argc, const char *const *argv);

/// Human-readable Windows backend build/version string.
const char *xtool_windows_backend_version(void);

#ifdef __cplusplus
}
#endif
