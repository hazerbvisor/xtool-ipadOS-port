#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-configure}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${SWIFT_COMPILER_TAG:-swift-6.3.2-RELEASE}"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$REPO_ROOT/.build/mobile-compiler-engine}"
SRC_ROOT="$WORK_ROOT/src"
BUILD_ROOT="$WORK_ROOT/build-ios"
PACKAGE_ROOT="$WORK_ROOT/package"
NATIVE_ROOT="$WORK_ROOT/native-tools"
DARWIN_ROOT="${DARWIN_SDK_ROOT:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}"
IOS_PLATFORM="$DARWIN_ROOT/Developer/Platforms/iPhoneOS.platform"
DARWIN_TOOLCHAIN="$DARWIN_ROOT/Developer/Toolchains/XcodeDefault.xctoolchain"
DEPLOYMENT="${XTOOL_IOS_DEPLOYMENT_TARGET:-16.0}"
TARGET="arm64-apple-ios${DEPLOYMENT}"
JOBS="${XTOOL_COMPILER_JOBS:-2}"
ENGINE_DYLIB="$PACKAGE_ROOT/libXToolCompilerEngine.dylib"

section() { printf '\n=== %s ===\n' "$1"; }
die() { echo "error: $*" >&2; exit 1; }

find_exec() {
  local name="$1"; shift
  local candidate
  for candidate in "$@"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  die "$name not found"
}

find_versioned_exec() {
  local pattern="$1"
  local candidate=""
  candidate="$(find /usr/bin /data/data/com.termux/files/usr/bin /opt/swift/usr/bin \
    -maxdepth 1 \( -type f -o -type l \) -name "$pattern" 2>/dev/null | sort -V | tail -1 || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

IOS_SDK=""
if [[ -d "$IOS_PLATFORM/Developer/SDKs" ]]; then
  IOS_SDK="$(find "$IOS_PLATFORM/Developer/SDKs" -maxdepth 1 -type d -name 'iPhoneOS*.sdk' | sort -V | tail -1 || true)"
fi
[[ -n "$IOS_SDK" ]] || die "iPhoneOS SDK not found under $IOS_PLATFORM/Developer/SDKs"
[[ -d "$DARWIN_TOOLCHAIN/usr/lib/swift/iphoneos" ]] || die "Darwin Swift iPhoneOS resource directory missing"

SWIFTC="$(find_exec swiftc /opt/swift/usr/bin/swiftc "$(command -v swiftc 2>/dev/null || true)")"
CLANG="$(find_exec clang /opt/swift/usr/bin/clang "$(command -v clang 2>/dev/null || true)")"
CLANGXX="$(find_exec clang++ /opt/swift/usr/bin/clang++ "$(command -v clang++ 2>/dev/null || true)")"
LLVM_AR="$(find_exec llvm-ar /opt/swift/usr/bin/llvm-ar "$(command -v llvm-ar 2>/dev/null || true)")"
LLVM_RANLIB="$(find_exec llvm-ranlib /opt/swift/usr/bin/llvm-ranlib "$(command -v llvm-ranlib 2>/dev/null || true)")"
LLVM_TBLGEN="$(find_exec llvm-tblgen /opt/swift/usr/bin/llvm-tblgen /data/data/com.termux/files/usr/bin/llvm-tblgen "$(command -v llvm-tblgen 2>/dev/null || true)")"
CLANG_TBLGEN="$(find_exec clang-tblgen /opt/swift/usr/bin/clang-tblgen /data/data/com.termux/files/usr/bin/clang-tblgen "$(command -v clang-tblgen 2>/dev/null || true)")"
NINJA="$(find_exec ninja /usr/bin/ninja /data/data/com.termux/files/usr/bin/ninja "$(command -v ninja 2>/dev/null || true)")"
CMAKE="$(find_exec cmake /usr/bin/cmake "$(command -v cmake 2>/dev/null || true)")"

INSTALL_NAME_TOOL=""
for candidate in \
  /opt/swift/usr/bin/llvm-install-name-tool \
  /data/data/com.termux/files/usr/bin/llvm-install-name-tool \
  /usr/bin/llvm-install-name-tool \
  "$(command -v llvm-install-name-tool 2>/dev/null || true)" \
  "$(command -v install_name_tool 2>/dev/null || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    INSTALL_NAME_TOOL="$candidate"
    break
  fi
done
if [[ -z "$INSTALL_NAME_TOOL" ]]; then
  INSTALL_NAME_TOOL="$(find_versioned_exec 'llvm-install-name-tool*' || true)"
fi

clone_release() {
  local url="$1"
  local dest="$2"
  local label="$3"
  if [[ -d "$dest/.git" ]]; then
    echo "$label source already present: $dest"
    return 0
  fi
  [[ ! -e "$dest" ]] || die "$dest exists but is not a git checkout"
  mkdir -p "$(dirname "$dest")"
  local tmp="$dest.tmp"
  rm -rf "$tmp"
  echo "Cloning $label @ $TAG ..."
  local attempt
  for attempt in 1 2 3; do
    if git -c http.version=HTTP/1.1 clone --depth 1 --single-branch --branch "$TAG" "$url" "$tmp"; then
      mv "$tmp" "$dest"
      return 0
    fi
    echo "clone attempt $attempt failed; retrying..." >&2
    rm -rf "$tmp"
  done
  die "failed to clone $label after 3 attempts"
}

patch_swift_cmark_lookup() {
  local file="$SRC_ROOT/swift/CMakeLists.txt"
  python3 - "$file" <<'PY'
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

prepare_sources() {
  section "source preparation"
  mkdir -p "$SRC_ROOT"
  clone_release https://github.com/swiftlang/swift.git "$SRC_ROOT/swift" Swift
  clone_release https://github.com/swiftlang/llvm-project.git "$SRC_ROOT/llvm-project" LLVM/Clang
  clone_release https://github.com/swiftlang/swift-cmark.git "$SRC_ROOT/cmark" Swift-cmark
  patch_swift_cmark_lookup
  echo "Swift HEAD:"; git -C "$SRC_ROOT/swift" log -1 --oneline
  echo "LLVM HEAD:"; git -C "$SRC_ROOT/llvm-project" log -1 --oneline
  echo "cmark HEAD:"; git -C "$SRC_ROOT/cmark" log -1 --oneline
}

prepare_native_tools() {
  mkdir -p "$NATIVE_ROOT/bin"
  ln -sfn "$LLVM_TBLGEN" "$NATIVE_ROOT/bin/llvm-tblgen"
  ln -sfn "$CLANG_TBLGEN" "$NATIVE_ROOT/bin/clang-tblgen"
  for tool in llvm-config llvm-profdata llvm-ar llvm-ranlib clang clang++; do
    local path=""
    path="$(command -v "$tool" 2>/dev/null || true)"
    if [[ -z "$path" && -x "/opt/swift/usr/bin/$tool" ]]; then path="/opt/swift/usr/bin/$tool"; fi
    if [[ -n "$path" ]]; then ln -sfn "$path" "$NATIVE_ROOT/bin/$tool"; fi
  done
}

configure_engine() {
  prepare_sources
  prepare_native_tools

  section "cross configuration"
  echo "target:             $TARGET"
  echo "SDK:                $IOS_SDK"
  echo "Swift tag:          $TAG"
  echo "build dir:          $BUILD_ROOT"
  echo "engine output:      $ENGINE_DYLIB"
  echo "llvm-tblgen:        $LLVM_TBLGEN"
  echo "clang-tblgen:       $CLANG_TBLGEN"
  echo "install-name-tool:  ${INSTALL_NAME_TOOL:-MISSING}"
  echo "Swift check:        forced valid for cross-compile"
  echo "cmark:              in-tree arm64 iOS external project"
  echo "XTool engine:       in-tree final dylib target"
  echo "Clang + LLD:        enabled in the base LLVM graph"
  echo "Clang shared tools: disabled (libclang, IndexStore, clang-shlib)"
  echo "LLVM host tools:    excluded from install/build"
  echo "jobs later:         $JOBS"

  [[ -n "$INSTALL_NAME_TOOL" ]] || die "llvm-install-name-tool not found. Install Debian LLVM tools and rerun."

  rm -rf "$BUILD_ROOT" "$PACKAGE_ROOT"
  mkdir -p "$BUILD_ROOT" "$PACKAGE_ROOT" "$WORK_ROOT/empty-string-processing" "$WORK_ROOT/empty-swift-syntax"

  "$CMAKE" -S "$SRC_ROOT/llvm-project/llvm" -B "$BUILD_ROOT" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_SYSROOT="$IOS_SDK" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_COMPILER="$CLANG" \
    -DCMAKE_CXX_COMPILER="$CLANGXX" \
    -DCMAKE_C_COMPILER_TARGET="$TARGET" \
    -DCMAKE_CXX_COMPILER_TARGET="$TARGET" \
    -DCMAKE_Swift_COMPILER="$SWIFTC" \
    -DCMAKE_Swift_COMPILER_TARGET="$TARGET" \
    -DCMAKE_Swift_COMPILER_FORCED=ON \
    -DCMAKE_Swift_FLAGS="-sdk $IOS_SDK -resource-dir $DARWIN_TOOLCHAIN/usr/lib/swift" \
    -DCMAKE_AR="$LLVM_AR" \
    -DCMAKE_RANLIB="$LLVM_RANLIB" \
    -DCMAKE_INSTALL_NAME_TOOL="$INSTALL_NAME_TOOL" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_EXTERNAL_PROJECTS="cmark;swift;xtoolcompiler" \
    -DLLVM_EXTERNAL_CMARK_SOURCE_DIR="$SRC_ROOT/cmark" \
    -DLLVM_EXTERNAL_SWIFT_SOURCE_DIR="$SRC_ROOT/swift" \
    -DLLVM_EXTERNAL_XTOOLCOMPILER_SOURCE_DIR="$REPO_ROOT/CompilerEngine" \
    -DLLVM_TARGETS_TO_BUILD=AArch64 \
    -DLLVM_HOST_TRIPLE="$TARGET" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$TARGET" \
    -DLLVM_TABLEGEN="$LLVM_TBLGEN" \
    -DCLANG_TABLEGEN="$CLANG_TBLGEN" \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
    -DLLVM_INCLUDE_TOOLS=ON \
    -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
    -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DLLVM_LINK_LLVM_DYLIB=OFF \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DCLANG_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DCLANG_BUILD_TOOLS=OFF \
    -DCLANG_TOOL_LIBCLANG_BUILD=OFF \
    -DCLANG_TOOL_INDEXSTORE_BUILD=OFF \
    -DCLANG_TOOL_CLANG_SHLIB_BUILD=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DSWIFT_HOST_VARIANT=iphoneos \
    -DSWIFT_HOST_VARIANT_SDK=IOS \
    -DSWIFT_HOST_VARIANT_ARCH=arm64 \
    -DSWIFT_PRIMARY_VARIANT_SDK=IOS \
    -DSWIFT_PRIMARY_VARIANT_ARCH=arm64 \
    -DSWIFT_SDK_IOS_PATH="$IOS_SDK" \
    -DSWIFT_SDK_IOS_ARCHITECTURES=arm64 \
    -DSWIFT_SDK_IOS_DEPLOYMENT_VERSION="$DEPLOYMENT" \
    -DSWIFT_DARWIN_DEPLOYMENT_VERSION_IOS="$DEPLOYMENT" \
    -DSWIFT_NATIVE_LLVM_TOOLS_PATH="$NATIVE_ROOT/bin" \
    -DSWIFT_NATIVE_CLANG_TOOLS_PATH="$NATIVE_ROOT/bin" \
    -DSWIFT_NATIVE_SWIFT_TOOLS_PATH="$(dirname "$SWIFTC")" \
    -DBOOTSTRAPPING_MODE=HOSTTOOLS \
    -DSWIFT_BUILD_IMMEDIATE_MODE=OFF \
    -DSWIFT_BUILD_SWIFT_SYNTAX=OFF \
    -DSWIFT_ENABLE_EXPERIMENTAL_STRING_PROCESSING=OFF \
    -DSWIFT_ENABLE_DISPATCH=OFF \
    -DSWIFT_BUILD_SOURCEKIT=OFF \
    -DSWIFT_INCLUDE_TESTS=OFF \
    -DSWIFT_INCLUDE_DOCS=OFF \
    -DSWIFT_BUILD_REMOTE_MIRROR=OFF \
    -DSWIFT_BUILD_DYNAMIC_STDLIB=OFF \
    -DSWIFT_BUILD_STATIC_STDLIB=OFF \
    -DSWIFT_BUILD_DYNAMIC_SDK_OVERLAY=OFF \
    -DSWIFT_BUILD_STATIC_SDK_OVERLAY=OFF \
    -DSWIFT_BUILD_STDLIB_EXTRA_TOOLCHAIN_CONTENT=OFF \
    -DSWIFT_BUILD_PERF_TESTSUITE=OFF \
    -DSWIFT_PATH_TO_STRING_PROCESSING_SOURCE="$WORK_ROOT/empty-string-processing" \
    -DSWIFT_PATH_TO_SWIFT_SYNTAX_SOURCE="$WORK_ROOT/empty-swift-syntax"

  section "configuration result"
  echo "CMake configuration completed."
  echo "Next command:"
  echo "  bash scripts/run-mobile-compiler-engine.sh build"
}

build_engine() {
  [[ -f "$BUILD_ROOT/build.ninja" ]] || die "compiler engine is not configured; run configure first"
  section "build XToolCompilerEngine dylib"
  echo "Using $JOBS parallel jobs to reduce memory pressure."
  echo "CMake will build only the dependency closure required by the final engine."
  "$CMAKE" --build "$BUILD_ROOT" --target XToolCompilerEngine -- -j "$JOBS"

  section "compiler engine result"
  [[ -f "$ENGINE_DYLIB" ]] || die "build completed but compiler engine dylib was not produced: $ENGINE_DYLIB"

  echo "Setting Mach-O install name to @rpath/libXToolCompilerEngine.dylib"
  "$INSTALL_NAME_TOOL" -id "@rpath/libXToolCompilerEngine.dylib" "$ENGINE_DYLIB"

  file "$ENGINE_DYLIB" || true
  du -h "$ENGINE_DYLIB" | awk '{print "size: "$1}'
  echo "SUCCESS: $ENGINE_DYLIB"
  echo "The mobile IPA packager will bundle this file automatically."
}

show_status() {
  section "status"
  echo "work root: $WORK_ROOT"
  du -sh "$WORK_ROOT" 2>/dev/null || true
  df -h "$WORK_ROOT" 2>/dev/null || true
  [[ -f "$BUILD_ROOT/build.ninja" ]] && echo "configured: yes" || echo "configured: no"
  if [[ -f "$ENGINE_DYLIB" ]]; then
    echo "compiler engine: $ENGINE_DYLIB"
    file "$ENGINE_DYLIB" 2>/dev/null || true
  else
    echo "compiler engine: not built"
  fi
}

case "$MODE" in
  prepare) prepare_sources; prepare_native_tools ;;
  configure) configure_engine ;;
  build) build_engine ;;
  status) show_status ;;
  *) echo "usage: $0 [prepare|configure|build|status]" >&2; exit 2 ;;
esac
