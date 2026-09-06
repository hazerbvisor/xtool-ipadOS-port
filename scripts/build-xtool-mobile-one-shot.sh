#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
BUILD_ROOT="$WORK_ROOT/build-ios"
ENGINE="$WORK_ROOT/package/libXToolCompilerEngine.dylib"
LOG="$ROOT/.build/xtool-mobile-one-shot.log"
CONFIGURATION="${CONFIGURATION:-debug}"
TRIPLE="${TRIPLE:-arm64-apple-ios}"
RUNTIME_ARCHIVE="$ROOT/.build/XToolMobileRuntime.tar"
RUNTIME_REV="swift-sdk-v6-validated-prebuilt-stdlib"
RUNTIME_REV_STAMP="$ROOT/.build/.xtool-mobile-runtime-rev"
IPA="$ROOT/.build/XToolMobileApp-unsigned.ipa"
IPA_ENGINE_PATH="Payload/XToolMobileApp.app/Frameworks/libXToolCompilerEngine.dylib"
COMPILER_CONFIG_REV="ios-clang-lld-v1"
COMPILER_CONFIG_STAMP="$WORK_ROOT/.xtool-compiler-config-rev"
COMPILER_ENGINE_REV="clang-lld-swiftmodules-v6"
COMPILER_ENGINE_STAMP="$WORK_ROOT/.xtool-compiler-engine-rev"

mkdir -p "$ROOT/.build"

copy_ipa_to_downloads() {
  local download_dir="${XTOOL_DOWNLOAD_DIR:-}"
  local destination

  if [[ -z "$download_dir" ]]; then
    for candidate in "/sdcard/Download" "$HOME/storage/downloads"; do
      if [[ -d "$candidate" && -w "$candidate" ]]; then
        download_dir="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$download_dir" ]]; then
    echo "Downloads export: skipped (no writable Downloads directory found)"
    echo "Set XTOOL_DOWNLOAD_DIR=/path/to/Downloads to enable automatic export."
    return 0
  fi

  destination="$download_dir/$(basename "$IPA")"
  cp -f "$IPA" "$destination"
  echo "Downloads export: $destination"
}

verify_ipa_engine() {
  [[ -f "$IPA" ]] || { echo "error: final IPA missing: $IPA" >&2; return 1; }
  python3 - "$IPA" "$IPA_ENGINE_PATH" <<'PY'
import sys, zipfile
ipa, required = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(ipa) as zf:
    names = set(zf.namelist())
    if required not in names:
        print(f"error: compiler engine is not inside final IPA: {required}", file=sys.stderr)
        sys.exit(1)
    info = zf.getinfo(required)
    print(f"verified IPA compiler engine: {required} ({info.file_size} bytes)")
PY
}

compiler_graph_is_usable() {
  [[ -f "$BUILD_ROOT/build.ninja" ]] || return 1
  grep -q 'XToolCompilerEngine' "$BUILD_ROOT/build.ninja"
}

compiler_graph_has_clang_lld() {
  compiler_graph_is_usable || return 1
  grep -q 'clangFrontendTool' "$BUILD_ROOT/build.ninja" || return 1
  grep -q 'lldMachO' "$BUILD_ROOT/build.ninja"
}

compiler_config_is_current() {
  compiler_graph_has_clang_lld || return 1
  [[ -f "$COMPILER_CONFIG_STAMP" ]] || return 1
  [[ "$(cat "$COMPILER_CONFIG_STAMP" 2>/dev/null || true)" == "$COMPILER_CONFIG_REV" ]]
}

compiler_engine_is_current() {
  [[ -f "$ENGINE" ]] || return 1
  [[ -f "$COMPILER_ENGINE_STAMP" ]] || return 1
  [[ "$(cat "$COMPILER_ENGINE_STAMP" 2>/dev/null || true)" == "$COMPILER_ENGINE_REV" ]]
}

runtime_is_current() {
  [[ -f "$RUNTIME_ARCHIVE" ]] || return 1
  [[ -f "$RUNTIME_REV_STAMP" ]] || return 1
  [[ "$(cat "$RUNTIME_REV_STAMP" 2>/dev/null || true)" == "$RUNTIME_REV" ]]
}

ensure_swiftdriver_resolved() {
  if [[ -f "$ROOT/Package.resolved" ]] && grep -q '"swift-driver"' "$ROOT/Package.resolved"; then
    echo 'cache hit: SwiftDriver dependency already resolved'
    return 0
  fi

  echo 'resolving SwiftDriver dependencies (one-time package step)'
  swift package resolve
}

run_all() {
  cd "$ROOT"

  echo '=== XTool Mobile one-shot bootstrap ==='
  echo "compiler work: $WORK_ROOT"
  echo "engine:        $ENGINE"
  echo "app config:    $CONFIGURATION"
  echo "app triple:    $TRIPLE"
  echo

  echo '=== mobile project pipeline checks ==='
  bash scripts/test-mobile-project.sh
  echo

  if compiler_graph_is_usable && ! compiler_graph_has_clang_lld; then
    echo 'error: the preserved compiler graph predates the Clang + LLD bootstrap.' >&2
    echo 'Run this cache-preserving upgrade once:' >&2
    echo '  XTOOL_COMPILER_JOBS=3 bash scripts/bootstrap-mobile-clang-lld.sh' >&2
    return 2
  fi

  if compiler_engine_is_current && compiler_graph_has_clang_lld; then
    echo '=== compiler engine ==='
    echo "cache hit: compiler engine revision $COMPILER_ENGINE_REV"
    file "$ENGINE" 2>/dev/null || true
    ls -lh "$ENGINE"
  else
    if compiler_graph_is_usable; then
      echo '=== compiler configure ==='
      if compiler_config_is_current; then
        echo 'cache hit: current CMake graph contains Swift + Clang + LLD engine targets'
      else
        echo 'existing working CMake graph found; preserving compiled object cache'
        echo 'backfilling config revision stamp without reconfiguring'
        printf '%s\n' "$COMPILER_CONFIG_REV" > "$COMPILER_CONFIG_STAMP"
      fi
      echo
      echo '=== compiler source compatibility patches ==='
      bash scripts/patch-mobile-compiler-ios-sources.sh
    else
      echo '=== compiler configure ==='
      bash scripts/run-mobile-compiler-engine.sh configure
      printf '%s\n' "$COMPILER_CONFIG_REV" > "$COMPILER_CONFIG_STAMP"
    fi

    echo
    echo '=== SDK opaque macro interface patch ==='
    bash scripts/patch-mobile-compiler-sdk-macro-interface.sh

    echo '=== compiler build ==='
    bash scripts/run-mobile-compiler-engine.sh build
    printf '%s\n' "$COMPILER_ENGINE_REV" > "$COMPILER_ENGINE_STAMP"
  fi

  [[ -f "$ENGINE" ]] || {
    echo "error: compiler build phase ended without final engine: $ENGINE" >&2
    return 1
  }

  echo
  echo '=== SwiftDriver package ==='
  ensure_swiftdriver_resolved

  echo
  echo '=== XTool Mobile app build ==='
  swift build \
    --disable-automatic-resolution \
    --product XToolMobileApp \
    --swift-sdk "$TRIPLE" \
    -c "$CONFIGURATION"

  echo
  echo '=== bundled Darwin runtime ==='
  if runtime_is_current; then
    echo "cache hit: runtime revision $RUNTIME_REV"
    echo "$RUNTIME_ARCHIVE"
  else
    echo "refreshing runtime for revision $RUNTIME_REV"
    bash scripts/prepare-mobile-runtime.sh
    printf '%s\n' "$RUNTIME_REV" > "$RUNTIME_REV_STAMP"
  fi

  echo
  echo '=== IPA package ==='
  CONFIGURATION="$CONFIGURATION" \
  TRIPLE="$TRIPLE" \
  COMPILER_ENGINE_DYLIB="$ENGINE" \
  REQUIRE_COMPILER_ENGINE=1 \
    bash scripts/package-mobile-app.sh

  echo
  echo '=== IPA verification ==='
  verify_ipa_engine

  echo
  echo '=== Downloads export ==='
  copy_ipa_to_downloads

  echo
  echo '=== SUCCESS ==='
  echo "Compiler engine: $ENGINE"
  echo "Compiler rev:    $COMPILER_ENGINE_REV"
  echo "Runtime rev:     $RUNTIME_REV"
  echo "Unsigned IPA:    $IPA"
}

set +e
(
  set -e
  run_all
) 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
  echo >&2
  echo "XTool Mobile bootstrap failed (exit $status)." >&2
  echo "Send this one log:" >&2
  echo "  $LOG" >&2
else
  echo
  echo "Full build log: $LOG"
fi

exit "$status"
