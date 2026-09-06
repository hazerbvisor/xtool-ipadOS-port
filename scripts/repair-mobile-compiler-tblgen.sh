#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
SRC_ROOT="$WORK_ROOT/src"
IOS_BUILD="$WORK_ROOT/build-ios"
HOST_BUILD="$WORK_ROOT/host-tblgen"
NATIVE_ROOT="$WORK_ROOT/native-tools"
JOBS="${XTOOL_COMPILER_JOBS:-2}"

section() { printf '\n=== %s ===\n' "$1"; }
die() { echo "error: $*" >&2; exit 1; }

pick_exec() {
  local name="$1"; shift
  local p
  for p in "$@"; do
    if [[ -n "$p" && -x "$p" ]]; then
      printf '%s' "$p"
      return 0
    fi
  done
  die "$name not found"
}

[[ -d "$SRC_ROOT/llvm-project/llvm" ]] || die "LLVM source is missing: $SRC_ROOT/llvm-project/llvm"
[[ -d "$SRC_ROOT/llvm-project/clang" ]] || die "Clang source is missing: $SRC_ROOT/llvm-project/clang"
[[ -f "$IOS_BUILD/build.ninja" ]] || die "iOS compiler build is not configured: $IOS_BUILD/build.ninja"

CMAKE="$(pick_exec cmake /usr/bin/cmake "$(command -v cmake 2>/dev/null || true)")"
NINJA="$(pick_exec ninja /usr/bin/ninja /data/data/com.termux/files/usr/bin/ninja "$(command -v ninja 2>/dev/null || true)")"
HOST_CC="$(pick_exec clang /opt/swift/usr/bin/clang /usr/bin/clang "$(command -v clang 2>/dev/null || true)")"
HOST_CXX="$(pick_exec clang++ /opt/swift/usr/bin/clang++ /usr/bin/clang++ "$(command -v clang++ 2>/dev/null || true)")"

HOST_LLVM_TBLGEN="$HOST_BUILD/bin/llvm-tblgen"
HOST_CLANG_TBLGEN="$HOST_BUILD/bin/clang-tblgen"

section "source-matched host TableGen"
echo "source:       $SRC_ROOT/llvm-project"
echo "host build:   $HOST_BUILD"
echo "host clang:   $HOST_CC"
echo "host clang++: $HOST_CXX"
echo "jobs:         $JOBS"

if [[ ! -x "$HOST_LLVM_TBLGEN" || ! -x "$HOST_CLANG_TBLGEN" ]]; then
  mkdir -p "$HOST_BUILD"
  "$CMAKE" -S "$SRC_ROOT/llvm-project/llvm" -B "$HOST_BUILD" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$HOST_CC" \
    -DCMAKE_CXX_COMPILER="$HOST_CXX" \
    -DLLVM_ENABLE_PROJECTS=clang \
    -DLLVM_TARGETS_TO_BUILD=AArch64 \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
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
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF

  "$CMAKE" --build "$HOST_BUILD" --target llvm-tblgen clang-tblgen -- -j "$JOBS"
else
  echo "cache hit: source-matched TableGen executables already exist"
fi

[[ -x "$HOST_LLVM_TBLGEN" ]] || die "source-matched llvm-tblgen was not produced"
[[ -x "$HOST_CLANG_TBLGEN" ]] || die "source-matched clang-tblgen was not produced"

section "host tool verification"
"$HOST_LLVM_TBLGEN" --version | head -n 3 || true
"$HOST_CLANG_TBLGEN" --version | head -n 3 || true
file "$HOST_LLVM_TBLGEN" || true
file "$HOST_CLANG_TBLGEN" || true

section "repair existing iOS build graph"
mkdir -p "$NATIVE_ROOT/bin"
ln -sfn "$HOST_LLVM_TBLGEN" "$NATIVE_ROOT/bin/llvm-tblgen"
ln -sfn "$HOST_CLANG_TBLGEN" "$NATIVE_ROOT/bin/clang-tblgen"

# Reconfigure the EXISTING build directory. Do not remove it: Ninja keeps the
# already-compiled iOS object files and only reruns rules whose command changed.
"$CMAKE" -S "$SRC_ROOT/llvm-project/llvm" -B "$IOS_BUILD" \
  -DLLVM_TABLEGEN="$HOST_LLVM_TBLGEN" \
  -DCLANG_TABLEGEN="$HOST_CLANG_TBLGEN" \
  -DSWIFT_NATIVE_LLVM_TOOLS_PATH="$NATIVE_ROOT/bin" \
  -DSWIFT_NATIVE_CLANG_TOOLS_PATH="$NATIVE_ROOT/bin"

section "smoke test the exact generator that crashed"
SMOKE_DIR="$WORK_ROOT/tblgen-smoke"
mkdir -p "$SMOKE_DIR"
"$HOST_CLANG_TBLGEN" \
  -gen-clang-attr-classes \
  -I"$SRC_ROOT/llvm-project/clang/include/clang/AST" \
  -I"$SRC_ROOT/llvm-project/clang/include" \
  -I"$IOS_BUILD/tools/clang/include" \
  -I"$IOS_BUILD/include" \
  -I"$SRC_ROOT/llvm-project/llvm/include" \
  "$SRC_ROOT/llvm-project/clang/include/clang/Basic/Attr.td" \
  -o "$SMOKE_DIR/Attrs.inc"

[[ -s "$SMOKE_DIR/Attrs.inc" ]] || die "source-matched clang-tblgen smoke test produced no output"

echo
 echo "SUCCESS: TableGen repaired without deleting the existing iOS build."
echo "Resume with:"
echo "  XTOOL_COMPILER_JOBS=$JOBS bash scripts/run-mobile-compiler-engine.sh build"
