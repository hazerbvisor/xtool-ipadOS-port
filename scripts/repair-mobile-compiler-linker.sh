#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
SRC_ROOT="$WORK_ROOT/src"
IOS_BUILD="$WORK_ROOT/build-ios"
HOST_BUILD="$WORK_ROOT/host-tblgen"
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
[[ -d "$SRC_ROOT/llvm-project/lld" ]] || die "LLD source is missing: $SRC_ROOT/llvm-project/lld"
[[ -f "$IOS_BUILD/build.ninja" ]] || die "iOS compiler build is not configured: $IOS_BUILD/build.ninja"

CMAKE="$(pick_exec cmake /usr/bin/cmake "$(command -v cmake 2>/dev/null || true)")"
NINJA="$(pick_exec ninja /usr/bin/ninja /data/data/com.termux/files/usr/bin/ninja "$(command -v ninja 2>/dev/null || true)")"
HOST_CC="$(pick_exec clang /opt/swift/usr/bin/clang /usr/bin/clang "$(command -v clang 2>/dev/null || true)")"
HOST_CXX="$(pick_exec clang++ /opt/swift/usr/bin/clang++ /usr/bin/clang++ "$(command -v clang++ 2>/dev/null || true)")"

HOST_LLD="$HOST_BUILD/bin/lld"
HOST_LD64="$HOST_BUILD/bin/ld64.lld"
INPUT_FILES="$SRC_ROOT/llvm-project/lld/MachO/InputFiles.cpp"

section "patch Swift's Linux iOS linker guard"
python3 - "$INPUT_FILES" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
block = '''  // Swift LLVM fork downstream change start\n  error("This version of lld does not support linking for platform " + getPlatformName(platformInfos.front().target.Platform));\n  return false;\n  // Swift LLVM fork downstream change end\n\n'''
if block in s:
    p.write_text(s.replace(block, '', 1))
    print('removed Swift downstream ld64.lld platform guard')
elif 'This version of lld does not support linking for platform' not in s:
    print('ld64.lld platform guard already removed')
else:
    raise SystemExit('error: found linker guard text but not the expected Swift 6.3.2 block')
PY

section "build source-matched host Mach-O linker"
echo "source:       $SRC_ROOT/llvm-project"
echo "host build:   $HOST_BUILD"
echo "host clang:   $HOST_CC"
echo "host clang++: $HOST_CXX"
echo "jobs:         $JOBS"

mkdir -p "$HOST_BUILD"
"$CMAKE" -S "$SRC_ROOT/llvm-project/llvm" -B "$HOST_BUILD" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$HOST_CC" \
  -DCMAKE_CXX_COMPILER="$HOST_CXX" \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_TARGETS_TO_BUILD=AArch64 \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_BUILD_UTILS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DCLANG_INCLUDE_TESTS=OFF \
  -DLLD_INCLUDE_TESTS=OFF \
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

"$CMAKE" --build "$HOST_BUILD" --target lld -- -j "$JOBS"
[[ -x "$HOST_LLD" ]] || die "host lld executable was not produced: $HOST_LLD"
ln -sfn "$HOST_LLD" "$HOST_LD64"
[[ -x "$HOST_LD64" ]] || die "ld64.lld shim was not produced: $HOST_LD64"

section "host linker verification"
"$HOST_LD64" --version | head -n 3 || true
file "$HOST_LD64" || true

section "rewire existing iOS build"
# Reconfigure the existing directory only. Do NOT remove it: all of the already
# compiled Swift/Clang/LLVM iOS archives remain valid and Ninja will retry the
# final link with this patched host Mach-O linker.
"$CMAKE" -S "$SRC_ROOT/llvm-project/llvm" -B "$IOS_BUILD" \
  -DXTOOL_MACHO_LINKER="$HOST_LD64"

if ! grep -Fq "$HOST_LD64" "$IOS_BUILD/build.ninja"; then
  die "existing iOS Ninja graph was not rewired to the patched Mach-O linker"
fi

echo
echo "SUCCESS: patched source-matched ld64.lld is ready."
echo "Existing iOS compiler objects were preserved."
echo "Resume with:"
echo "  XTOOL_COMPILER_JOBS=$JOBS bash scripts/run-mobile-compiler-engine.sh build"
