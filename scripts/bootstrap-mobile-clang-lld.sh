#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
SRC_ROOT="$WORK_ROOT/src"
BUILD_ROOT="$WORK_ROOT/build-ios"
LLVM_SOURCE="$SRC_ROOT/llvm-project/llvm"
ENGINE="$WORK_ROOT/package/libXToolCompilerEngine.dylib"
ENGINE_REV="clang-lld-bootstrap-v1"
ENGINE_STAMP="$WORK_ROOT/.xtool-compiler-engine-rev"
CONFIG_REV="ios-clang-lld-v1"
CONFIG_STAMP="$WORK_ROOT/.xtool-compiler-config-rev"
JOBS="${XTOOL_COMPILER_JOBS:-2}"
LOG="$WORK_ROOT/bootstrap-clang-lld.log"

CMAKE="$(command -v cmake 2>/dev/null || true)"
[[ -n "$CMAKE" ]] || { echo "error: cmake not found" >&2; exit 1; }
[[ -f "$BUILD_ROOT/build.ninja" ]] || {
  echo "error: existing mobile compiler build graph not found: $BUILD_ROOT/build.ninja" >&2
  echo "This bootstrap is intentionally cache-preserving and will not create a clean build." >&2
  exit 1
}
[[ -f "$LLVM_SOURCE/CMakeLists.txt" ]] || {
  echo "error: existing LLVM source tree not found: $LLVM_SOURCE" >&2
  exit 1
}

run_bootstrap() {
  cd "$ROOT"

  echo '=== XTool Mobile Clang + LLD bootstrap ==='
  echo "work root:  $WORK_ROOT"
  echo "build root: $BUILD_ROOT"
  echo "jobs:       $JOBS"
  echo
  echo 'This preserves the existing LLVM/Clang/Swift object cache.'
  echo 'No build directory is removed by this script.'
  echo

  echo '=== source compatibility patches ==='
  bash scripts/patch-mobile-compiler-ios-sources.sh
  # The all-in-one iOS patcher above already handles the macro language gate.
  # Keep only the distinct SDK-interface diagnostic patch here so the same
  # LangOptions.cpp transformation is not applied twice with different text.
  bash scripts/patch-mobile-compiler-sdk-macro-interface.sh

  echo
  echo '=== enable LLD libraries in existing CMake graph ==='
  # XTool embeds lldMachO as a library and never launches the lld command-line
  # executable. On an iOS CMake target, executables are modeled as bundles;
  # upstream LLD's tool install rule has no BUNDLE DESTINATION and therefore
  # fails configuration. Disable the unnecessary LLD tools while keeping all
  # LLD libraries/targets available to XToolCompilerEngine.
  "$CMAKE" \
    -S "$LLVM_SOURCE" \
    -B "$BUILD_ROOT" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLD_BUILD_TOOLS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF

  if ! grep -q 'lldMachO' "$BUILD_ROOT/build.ninja"; then
    echo "error: CMake regeneration completed but lldMachO is missing from build.ninja" >&2
    exit 1
  fi
  if ! grep -q 'clangFrontendTool' "$BUILD_ROOT/build.ninja"; then
    echo "error: clangFrontendTool is missing from the preserved build graph" >&2
    exit 1
  fi

  printf '%s\n' "$CONFIG_REV" > "$CONFIG_STAMP"
  echo "CMake graph: Clang frontend + Mach-O LLD libraries enabled"

  echo
  echo '=== incremental engine build ==='
  XTOOL_COMPILER_JOBS="$JOBS" bash scripts/run-mobile-compiler-engine.sh build

  [[ -f "$ENGINE" ]] || {
    echo "error: engine build finished without $ENGINE" >&2
    exit 1
  }

  printf '%s\n' "$ENGINE_REV" > "$ENGINE_STAMP"

  echo
  echo '=== native bridge symbol check ==='
  if command -v llvm-nm >/dev/null 2>&1; then
    llvm-nm -g "$ENGINE" 2>/dev/null | grep -E 'xtool_(swift_frontend_run|clang_frontend_run|lld_macho_run)' || true
  elif command -v nm >/dev/null 2>&1; then
    nm -g "$ENGINE" 2>/dev/null | grep -E 'xtool_(swift_frontend_run|clang_frontend_run|lld_macho_run)' || true
  else
    echo 'nm unavailable; symbol verification will happen through dlopen/dlsym on iPad.'
  fi

  echo
  echo '=== package updated XTool Mobile IPA ==='
  bash scripts/build-xtool-mobile-one-shot.sh

  echo
  echo '=== SUCCESS ==='
  echo "engine: $ENGINE"
  echo "engine revision: $ENGINE_REV"
  echo "IPA: $ROOT/.build/XToolMobileApp-unsigned.ipa"
}

mkdir -p "$WORK_ROOT"
set +e
(
  set -e
  run_bootstrap
) 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
  echo >&2
  echo "Clang + LLD bootstrap failed (exit $status)." >&2
  echo "Send this one log:" >&2
  echo "  $LOG" >&2
fi

exit "$status"
