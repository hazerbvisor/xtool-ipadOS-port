#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Stable ABI exposed to XToolMobileCore.
/// argv contains Swift frontend arguments consumed directly by
/// swift::performFrontend; do not include the driver's `-frontend` marker.
int32_t xtool_swift_frontend_run(int32_t argc, const char *const *argv);

/// Run Clang's cc1 frontend in-process.
/// argv contains cc1-style frontend arguments, but must not include an argv[0]
/// element or the driver's `-cc1` dispatch marker.
int32_t xtool_clang_frontend_run(int32_t argc, const char *const *argv);

/// Run LLD's Mach-O linker in-process.
/// argv contains ld64-style linker arguments. The bridge supplies argv[0]
/// (`ld64.lld`) before entering lldMain.
int32_t xtool_lld_macho_run(int32_t argc, const char *const *argv);

/// Human-readable compiler engine build/version string.
const char *xtool_compiler_engine_version(void);

#ifdef __cplusplus
}
#endif
