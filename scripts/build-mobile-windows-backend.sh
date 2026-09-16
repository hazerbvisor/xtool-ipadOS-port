#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-configure}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${SWIFT_COMPILER_TAG:-swift-6.3.2-RELEASE}"
WORK_ROOT="${XTOOL_WINDOWS_WORK:-$ROOT/.build/mobile-windows-backend}"
BUILD_ROOT="$WORK_ROOT/build-ios"
PACKAGE_ROOT="$WORK_ROOT/package"
NATIVE_ROOT="$WORK_ROOT/native-tools"
DARWIN_ROOT="${DARWIN_SDK_ROOT:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}"
IOS_PLATFORM="$DARWIN_ROOT/Developer/Platforms/iPhoneOS.platform"
DEPLOYMENT="${XTOOL_IOS_DEPLOYMENT_TARGET:-16.0}"
TARGET="arm64-apple-ios${DEPLOYMENT}"
JOBS="${XTOOL_WINDOWS_JOBS:-${XTOOL_COMPILER_JOBS:-2}}"
BACKEND_DYLIB="$PACKAGE_ROOT/libXToolWindowsBackend.dylib"

# Reuse the existing source checkout if possible, but this build has a separate
# CMake graph and enables only LLVM + LLD. It does NOT configure Swift or Clang.
DEFAULT_SHARED_LLVM="$ROOT/.build/mobile-compiler-engine/src/llvm-project"
LLVM_SOURCE="${XTOOL_LLVM_SOURCE:-$DEFAULT_SHARED_LLVM}"
if [[ ! -d "$LLVM_SOURCE/.git" ]]; then
  LLVM_SOURCE="$WORK_ROOT/src/llvm-project"
fi

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

IOS_SDK=""
if [[ -d "$IOS_PLATFORM/Developer/SDKs" ]]; then
  IOS_SDK="$(find "$IOS_PLATFORM/Developer/SDKs" -maxdepth 1 -type d -name 'iPhoneOS*.sdk' | sort -V | tail -1 || true)"
fi
[[ -n "$IOS_SDK" ]] || die "iPhoneOS SDK not found under $IOS_PLATFORM/Developer/SDKs"

CLANG="$(find_exec clang /opt/swift/usr/bin/clang /usr/bin/clang /data/data/com.termux/files/usr/bin/clang "$(command -v clang 2>/dev/null || true)")"
CLANGXX="$(find_exec clang++ /opt/swift/usr/bin/clang++ /usr/bin/clang++ /data/data/com.termux/files/usr/bin/clang++ "$(command -v clang++ 2>/dev/null || true)")"
LLVM_AR="$(find_exec llvm-ar /opt/swift/usr/bin/llvm-ar /usr/bin/llvm-ar /data/data/com.termux/files/usr/bin/llvm-ar "$(command -v llvm-ar 2>/dev/null || true)")"
LLVM_RANLIB="$(find_exec llvm-ranlib /opt/swift/usr/bin/llvm-ranlib /usr/bin/llvm-ranlib /data/data/com.termux/files/usr/bin/llvm-ranlib "$(command -v llvm-ranlib 2>/dev/null || true)")"
LLVM_TBLGEN="$(find_exec llvm-tblgen /opt/swift/usr/bin/llvm-tblgen /usr/bin/llvm-tblgen /data/data/com.termux/files/usr/bin/llvm-tblgen "$(command -v llvm-tblgen 2>/dev/null || true)")"
NINJA="$(find_exec ninja /usr/bin/ninja /data/data/com.termux/files/usr/bin/ninja "$(command -v ninja 2>/dev/null || true)")"
CMAKE="$(find_exec cmake /usr/bin/cmake /data/data/com.termux/files/usr/bin/cmake "$(command -v cmake 2>/dev/null || true)")"
INSTALL_NAME_TOOL="$(find_exec llvm-install-name-tool /opt/swift/usr/bin/llvm-install-name-tool /usr/bin/llvm-install-name-tool /data/data/com.termux/files/usr/bin/llvm-install-name-tool "$(command -v llvm-install-name-tool 2>/dev/null || true)")"

prepare_source() {
  if [[ -d "$LLVM_SOURCE/.git" ]]; then
    echo "LLVM source already present: $LLVM_SOURCE"
    return 0
  fi
  mkdir -p "$(dirname "$LLVM_SOURCE")"
  echo "Cloning LLVM/LLD @ $TAG ..."
  git -c http.version=HTTP/1.1 clone --depth 1 --single-branch --branch "$TAG" \
    https://github.com/swiftlang/llvm-project.git "$LLVM_SOURCE"
}

prepare_native_tools() {
  mkdir -p "$NATIVE_ROOT/bin"
  ln -sfn "$LLVM_TBLGEN" "$NATIVE_ROOT/bin/llvm-tblgen"
}

configure_backend() {
  prepare_source
  prepare_native_tools
  mkdir -p "$BUILD_ROOT" "$PACKAGE_ROOT"

  local macho_linker="${XTOOL_MACHO_LINKER:-}"
  if [[ -z "$macho_linker" && -x "$ROOT/.build/mobile-compiler-engine/host-tblgen/bin/ld64.lld" ]]; then
    macho_linker="$ROOT/.build/mobile-compiler-engine/host-tblgen/bin/ld64.lld"
  fi

  section "Windows backend cross configuration"
  echo "host dylib target:  $TARGET"
  echo "LLVM codegen:       X86 only"
  echo "Windows linker:     lldCOFF"
  echo "Clang project:      NOT INCLUDED"
  echo "Swift project:      NOT INCLUDED"
  echo "input from XTool:   LLVM bitcode"
  echo "SDK:                $IOS_SDK"
  echo "LLVM source:        $LLVM_SOURCE"
  echo "build dir:          $BUILD_ROOT"
  echo "output:             $BACKEND_DYLIB"
  echo "Mach-O host linker: ${macho_linker:-default lld}"
  echo "jobs later:         $JOBS"

  local extra_linker=()
  if [[ -n "$macho_linker" ]]; then
    extra_linker=(-DXTOOL_MACHO_LINKER="$macho_linker")
  fi

  "$CMAKE" -S "$LLVM_SOURCE/llvm" -B "$BUILD_ROOT" -G Ninja \
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
    -DCMAKE_AR="$LLVM_AR" \
    -DCMAKE_RANLIB="$LLVM_RANLIB" \
    -DCMAKE_INSTALL_NAME_TOOL="$INSTALL_NAME_TOOL" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DLLVM_ENABLE_PROJECTS="lld" \
    -DLLVM_EXTERNAL_PROJECTS="xtoolwindows" \
    -DLLVM_EXTERNAL_XTOOLWINDOWS_SOURCE_DIR="$ROOT/WindowsBackend" \
    -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_HOST_TRIPLE="$TARGET" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$TARGET" \
    -DLLVM_TABLEGEN="$LLVM_TBLGEN" \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLD_BUILD_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
    -DLLVM_INCLUDE_TOOLS=ON \
    -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
    -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DLLVM_LINK_LLVM_DYLIB=OFF \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLD_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    "${extra_linker[@]}"

  section "configuration result"
  echo "CMake configuration completed."
  echo "Ninja work items for LLVM-bitcode -> X86 COFF backend:"
  "$NINJA" -C "$BUILD_ROOT" -n XToolWindowsBackend 2>/dev/null | tail -n 1 || true
  echo "Next: bash scripts/build-mobile-windows-backend.sh build"
}

build_backend() {
  [[ -f "$BUILD_ROOT/build.ninja" ]] || die "Windows backend is not configured; run configure first"
  section "build isolated XToolWindowsBackend dylib"
  "$CMAKE" --build "$BUILD_ROOT" --target XToolWindowsBackend -- -j "$JOBS"

  [[ -f "$BACKEND_DYLIB" ]] || die "backend build finished without $BACKEND_DYLIB"
  "$INSTALL_NAME_TOOL" -id "@rpath/libXToolWindowsBackend.dylib" "$BACKEND_DYLIB"

  section "Windows backend result"
  file "$BACKEND_DYLIB" 2>/dev/null || true
  du -h "$BACKEND_DYLIB" | awk '{print "size: "$1}'
  echo "SUCCESS: $BACKEND_DYLIB"
}

show_status() {
  section "Windows backend status"
  echo "work root: $WORK_ROOT"
  [[ -f "$BUILD_ROOT/build.ninja" ]] && echo "configured: yes" || echo "configured: no"
  if [[ -f "$BACKEND_DYLIB" ]]; then
    echo "backend: $BACKEND_DYLIB"
    file "$BACKEND_DYLIB" 2>/dev/null || true
  else
    echo "backend: not built"
  fi
}

case "$MODE" in
  prepare) prepare_source; prepare_native_tools ;;
  configure) configure_backend ;;
  build) build_backend ;;
  status) show_status ;;
  *) echo "usage: $0 [prepare|configure|build|status]" >&2; exit 2 ;;
esac
