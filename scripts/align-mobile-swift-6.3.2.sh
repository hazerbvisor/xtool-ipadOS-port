#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
SRC_ROOT="$WORK_ROOT/src"
SWIFT_SOURCE="$SRC_ROOT/swift"
LLVM_SOURCE="$SRC_ROOT/llvm-project/llvm"
BUILD_ROOT="$WORK_ROOT/build-ios"
ENGINE="$WORK_ROOT/package/libXToolCompilerEngine.dylib"
TAG="swift-6.3.2-RELEASE"
EXPECTED_SWIFT_COMMIT="cd8d8ad0019e4e291906b311e0d25d7039cddc9c"
ENGINE_VERSION="swift-6.3.2-RELEASE+clang+lld"
ENGINE_STAMP="$WORK_ROOT/.xtool-compiler-engine-rev"
CURRENT_ENGINE_REV="clang-lld-bootstrap-v1"
REQUIRED_HOST_SWIFT="6.3.2"
JOBS="${XTOOL_COMPILER_JOBS:-2}"
LOG="$WORK_ROOT/align-swift-6.3.2.log"

CMAKE="$(command -v cmake 2>/dev/null || true)"
HOST_SWIFTC="${XTOOL_HOST_SWIFTC:-$(command -v swiftc 2>/dev/null || true)}"
HOST_SWIFT_BIN="$(dirname "$HOST_SWIFTC")"

[[ -n "$CMAKE" ]] || { echo "error: cmake not found" >&2; exit 1; }
[[ -n "$HOST_SWIFTC" && -x "$HOST_SWIFTC" ]] || {
  echo "error: host swiftc not found" >&2
  exit 1
}
[[ -x "$HOST_SWIFT_BIN/swift" ]] || {
  echo "error: sibling swift driver not found next to $HOST_SWIFTC" >&2
  exit 1
}
[[ -f "$BUILD_ROOT/build.ninja" ]] || {
  echo "error: preserved compiler build graph is missing: $BUILD_ROOT/build.ninja" >&2
  echo "Refusing to perform a clean compiler build." >&2
  exit 1
}
[[ -d "$SWIFT_SOURCE/.git" ]] || {
  echo "error: Swift source checkout is missing: $SWIFT_SOURCE" >&2
  exit 1
}
[[ -f "$LLVM_SOURCE/CMakeLists.txt" ]] || {
  echo "error: LLVM source checkout is missing: $LLVM_SOURCE" >&2
  exit 1
}

grep -q 'XToolCompilerEngine' "$BUILD_ROOT/build.ninja" || {
  echo 'error: preserved graph does not contain XToolCompilerEngine' >&2
  exit 1
}
grep -q 'clangFrontendTool' "$BUILD_ROOT/build.ninja" || {
  echo 'error: preserved graph does not contain Clang frontend support' >&2
  exit 1
}
grep -q 'lldMachO' "$BUILD_ROOT/build.ninja" || {
  echo 'error: preserved graph does not contain Mach-O LLD support' >&2
  exit 1
}

check_host_swift() {
  local version
  version="$($HOST_SWIFTC --version 2>&1 | head -n 1 || true)"
  echo "host swiftc:  $HOST_SWIFTC"
  echo "host version: ${version:-unknown}"
  if [[ "$version" != *"Swift version $REQUIRED_HOST_SWIFT"* ]]; then
    echo >&2
    echo "error: Xcode 26.5 runtime alignment requires host Swift $REQUIRED_HOST_SWIFT" >&2
    echo "The installed SDK/runtime must be rebound with the same Swift toolchain used by the embedded frontend." >&2
    echo "Select/install Swift $REQUIRED_HOST_SWIFT, then rerun this script." >&2
    exit 2
  fi
}

checkout_swift_release() {
  echo "Fetching $TAG into the existing shallow Swift checkout..."
  git -C "$SWIFT_SOURCE" -c http.version=HTTP/1.1 fetch --depth 1 --force \
    origin "refs/tags/$TAG:refs/tags/$TAG"

  # Reset only the Swift source checkout. build-ios contains the expensive
  # LLVM/Clang/LLD object cache and is deliberately preserved.
  git -C "$SWIFT_SOURCE" reset --hard "$TAG"

  local actual
  actual="$(git -C "$SWIFT_SOURCE" rev-parse HEAD)"
  if [[ "$actual" != "$EXPECTED_SWIFT_COMMIT" ]]; then
    echo "error: unexpected $TAG commit: $actual" >&2
    echo "expected: $EXPECTED_SWIFT_COMMIT" >&2
    exit 1
  fi
  echo "Swift source: $TAG ($actual)"
}

patch_cmark_lookup() {
  python3 - "$SWIFT_SOURCE/CMakeLists.txt" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = 'elseif(SWIFT_INCLUDE_TOOLS)\n  find_package(cmark-gfm CONFIG REQUIRED)'
new = 'elseif(SWIFT_INCLUDE_TOOLS AND NOT "cmark" IN_LIST LLVM_EXTERNAL_PROJECTS)\n  find_package(cmark-gfm CONFIG REQUIRED)'
if new in s:
    print('Swift cmark external-project guard: already applied')
elif old in s:
    p.write_text(s.replace(old, new, 1))
    print('Swift cmark external-project guard: applied')
else:
    raise SystemExit('error: expected Swift cmark lookup block not found')
PY
}

run_alignment() {
  cd "$ROOT"

  echo '=== XTool Mobile Swift 6.3.2 / Xcode 26.5 alignment ==='
  echo "work root:    $WORK_ROOT"
  echo "build root:   $BUILD_ROOT"
  echo "Swift target: $TAG"
  echo "jobs:         $JOBS"
  echo
  echo 'This script DOES NOT delete build-ios or the LLVM/Clang/LLD object cache.'
  echo 'It changes only the Swift frontend source revision and rebuilds what Ninja marks stale.'
  echo

  echo '=== host toolchain check ==='
  check_host_swift

  echo
  echo '=== Swift source alignment ==='
  checkout_swift_release
  patch_cmark_lookup

  echo
  echo '=== reapply XTool iOS compiler patches ==='
  bash scripts/patch-mobile-compiler-ios-sources.sh
  bash scripts/patch-mobile-compiler-sdk-macro-interface.sh

  echo
  echo '=== regenerate preserved CMake graph ==='
  "$CMAKE" \
    -S "$LLVM_SOURCE" \
    -B "$BUILD_ROOT" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLD_BUILD_TOOLS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DXTOOL_COMPILER_ENGINE_VERSION="$ENGINE_VERSION"

  grep -q 'XToolCompilerEngine' "$BUILD_ROOT/build.ninja" || {
    echo 'error: XToolCompilerEngine disappeared from the preserved graph' >&2
    exit 1
  }
  grep -q 'clangFrontendTool' "$BUILD_ROOT/build.ninja" || {
    echo 'error: clangFrontendTool disappeared from the preserved graph' >&2
    exit 1
  }
  grep -q 'lldMachO' "$BUILD_ROOT/build.ninja" || {
    echo 'error: lldMachO disappeared from the preserved graph' >&2
    exit 1
  }

  echo
  echo '=== incremental Swift frontend engine rebuild ==='
  XTOOL_COMPILER_JOBS="$JOBS" bash scripts/run-mobile-compiler-engine.sh build

  [[ -f "$ENGINE" ]] || {
    echo "error: engine build completed without $ENGINE" >&2
    exit 1
  }

  # The engine still has the same Swift+Clang+LLD capabilities; only the Swift
  # frontend revision changed. Preserve the existing capability stamp so the
  # normal one-shot packager uses this freshly rebuilt dylib.
  printf '%s\n' "$CURRENT_ENGINE_REV" > "$ENGINE_STAMP"

  echo
  echo '=== package aligned IPA + refresh bound runtime ==='
  PATH="$HOST_SWIFT_BIN:$PATH" \
  XTOOL_HOST_SWIFTC="$HOST_SWIFTC" \
    bash scripts/build-xtool-mobile-one-shot.sh

  echo
  echo '=== SUCCESS ==='
  echo "Swift source:  $TAG"
  echo "Engine:        $ENGINE"
  echo "Engine label:  $ENGINE_VERSION"
  echo "Runtime:       swift-sdk-v4-swift-6.3.2-bound"
  echo "Unsigned IPA:  $ROOT/.build/XToolMobileApp-unsigned.ipa"
}

mkdir -p "$WORK_ROOT"
set +e
(
  set -e
  run_alignment
) 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
  echo >&2
  echo "Swift 6.3.2 alignment failed (exit $status)." >&2
  echo "Send this one log:" >&2
  echo "  $LOG" >&2
fi

exit "$status"
