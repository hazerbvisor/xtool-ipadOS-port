#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
SWIFT_COMPILER_SOURCES_CMAKE="$WORK_ROOT/src/swift/SwiftCompilerSources/CMakeLists.txt"

[[ -f "$SWIFT_COMPILER_SOURCES_CMAKE" ]] || {
  echo "error: SwiftCompilerSources CMakeLists.txt not found: $SWIFT_COMPILER_SOURCES_CMAKE" >&2
  exit 1
}

python3 - "$SWIFT_COMPILER_SOURCES_CMAKE" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
original = s

anchor = '''  set(sdk_option ${SWIFT_COMPILER_SOURCES_SDK_FLAGS})
'''

old_patch = '''  set(sdk_option ${SWIFT_COMPILER_SOURCES_SDK_FLAGS})

  # XTool Mobile cross-build fix: SwiftCompilerSources is compiled by the
  # Linux-hosted swiftc but targets iPhoneOS. CMake's custom Swift compiler
  # source rule does not inherit CMAKE_Swift_FLAGS, so without an explicit
  # Darwin resource directory it falls back to the SDK Swift.swiftinterface
  # and cannot resolve SwiftShims. Derive the extracted Xcode toolchain from
  # the iPhoneOS SDK path and mirror the already-working Linux -> iOS frontend
  # resource/include setup.
  if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND XTOOL_FRONTEND_LIBRARY_ONLY)
    get_filename_component(
      xtool_darwin_developer
      "${sdk_path}/../../../../.."
      ABSOLUTE
    )
    set(
      xtool_darwin_swift_resources
      "${xtool_darwin_developer}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"
    )
    list(APPEND sdk_option
      "-resource-dir" "${xtool_darwin_swift_resources}"
      "-I" "${xtool_darwin_swift_resources}/iphoneos"
      "-I" "${sdk_path}/../../usr/lib"
      "-Xcc" "-isystem"
      "-Xcc" "${xtool_darwin_swift_resources}/clang/include"
    )
  endif()
'''

new_patch = '''  set(sdk_option ${SWIFT_COMPILER_SOURCES_SDK_FLAGS})

  # XTool Mobile cross-build fix: SwiftCompilerSources is compiled by the
  # Linux-hosted swiftc but targets iPhoneOS. CMake's custom Swift compiler
  # source rule does not inherit CMAKE_Swift_FLAGS, so without an explicit
  # Darwin resource directory it falls back to the SDK Swift.swiftinterface
  # and cannot resolve SwiftShims. Derive the extracted Xcode toolchain from
  # the iPhoneOS SDK path and mirror the working Linux -> iOS Swift resource
  # layout.
  #
  # Do NOT add the Clang builtin-header directory with an explicit -isystem.
  # For SwiftCompilerSources, ClangImporter also imports libc++ through C++
  # interop. Forcing clang/include ahead of libc++ breaks libc++'s wrapper
  # headers (for example cstddef -> stddef.h and cfloat -> float.h). The
  # frontend discovers its builtin headers from -resource-dir in the correct
  # relative order automatically.
  if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND XTOOL_FRONTEND_LIBRARY_ONLY)
    get_filename_component(
      xtool_darwin_developer
      "${sdk_path}/../../../../.."
      ABSOLUTE
    )
    set(
      xtool_darwin_swift_resources
      "${xtool_darwin_developer}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"
    )
    list(APPEND sdk_option
      "-resource-dir" "${xtool_darwin_swift_resources}"
      "-I" "${xtool_darwin_swift_resources}/iphoneos"
      "-I" "${sdk_path}/../../usr/lib"
    )
  endif()
'''

if new_patch in s:
    print('SwiftCompilerSources Darwin resource-dir fix: already applied (libc++ safe)')
elif old_patch in s:
    s = s.replace(old_patch, new_patch, 1)
    print('SwiftCompilerSources Darwin resource-dir fix: upgraded to libc++-safe ordering')
elif anchor in s:
    s = s.replace(anchor, new_patch, 1)
    print('SwiftCompilerSources Darwin resource-dir fix: applied (libc++ safe)')
else:
    raise SystemExit('error: expected SwiftCompilerSources sdk_option anchor not found')

# Upstream also adds the executing compiler's ../lib to find swift/shims
# headers imported by SILBridging. For a Linux -> iOS build that exposes a
# second SwiftShims module map alongside the one already supplied by the SDK.
# Select the SDK headers before either the swiftly or ordinary host fallback.
host_anchor = '''  elseif(swift_exec_bin_dir MATCHES ".*/swiftly/bin")
'''
target_shims_patch = '''  elseif(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND XTOOL_FRONTEND_LIBRARY_ONLY)
    # XTool Mobile: resolve swift/shims headers from the target SDK only.
    # Adding the Linux compiler's ../lib imports duplicate SwiftShims,
    # _SwiftConcurrencyShims, SwiftOverlayShims and _SynchronizationShims.
    if(NOT EXISTS "${sdk_path}/usr/lib/swift/shims/module.modulemap")
      message(FATAL_ERROR "XTool Mobile: Swift shim module map missing from iPhoneOS SDK: ${sdk_path}/usr/lib/swift/shims/module.modulemap")
    endif()
    list(APPEND sdk_option "-I" "${sdk_path}/usr/lib")

  elseif(swift_exec_bin_dir MATCHES ".*/swiftly/bin")
'''

if target_shims_patch in s:
    print('SwiftCompilerSources target-only SwiftShims fix: already applied')
elif s.count(host_anchor) == 1:
    s = s.replace(host_anchor, target_shims_patch, 1)
    print('SwiftCompilerSources target-only SwiftShims fix: applied')
else:
    raise SystemExit('error: expected SwiftCompilerSources host shim lookup anchor not found; no changes written')

# Commit both changes together after validating all expected source anchors.
# Avoid touching the file on retries so Ninja need not regenerate needlessly.
if s != original:
    p.write_text(s)
PY
