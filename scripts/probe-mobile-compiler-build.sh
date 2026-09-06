#!/usr/bin/env bash
set -euo pipefail

SWIFT_ROOT="${SWIFT_ROOT:-/opt/swift}"
DARWIN_ROOT="${DARWIN_SDK_ROOT:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}"
IOS_PLATFORM="$DARWIN_ROOT/Developer/Platforms/iPhoneOS.platform"
IOS_SDK=""

section() { printf '\n=== %s ===\n' "$1"; }
show_tool() {
  local name="$1"
  shift
  for candidate in "$@"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%-18s %s\n' "$name" "$candidate"
      return 0
    fi
  done
  printf '%-18s MISSING\n' "$name"
  return 1
}

if [[ -d "$IOS_PLATFORM/Developer/SDKs" ]]; then
  IOS_SDK="$(find "$IOS_PLATFORM/Developer/SDKs" -maxdepth 1 -type d -name 'iPhoneOS*.sdk' | sort -V | tail -1 || true)"
fi

section "host resources"
uname -a || true
printf 'cores: '; nproc 2>/dev/null || true
free -h 2>/dev/null || true
df -h /root 2>/dev/null || true

section "toolchain versions"
swift --version 2>/dev/null || true
clang --version 2>/dev/null | head -3 || true
cmake --version 2>/dev/null | head -1 || true
ninja --version 2>/dev/null || true
python3 --version 2>/dev/null || true

section "Darwin SDK"
if [[ -n "$IOS_SDK" ]]; then
  echo "iPhoneOS SDK: $IOS_SDK"
  du -sh "$IOS_SDK" 2>/dev/null || true
else
  echo "iPhoneOS SDK: MISSING"
fi

section "native build tools"
missing=0
show_tool swiftc \
  "$SWIFT_ROOT/usr/bin/swiftc" "$(command -v swiftc 2>/dev/null || true)" || missing=1
show_tool clang \
  "$SWIFT_ROOT/usr/bin/clang" "$(command -v clang 2>/dev/null || true)" || missing=1
show_tool clang++ \
  "$SWIFT_ROOT/usr/bin/clang++" "$(command -v clang++ 2>/dev/null || true)" || missing=1
show_tool ld.lld \
  "$SWIFT_ROOT/usr/bin/ld.lld" "$(command -v ld.lld 2>/dev/null || true)" || missing=1
show_tool llvm-ar \
  "$SWIFT_ROOT/usr/bin/llvm-ar" "$(command -v llvm-ar 2>/dev/null || true)" || missing=1
show_tool llvm-ranlib \
  "$SWIFT_ROOT/usr/bin/llvm-ranlib" "$(command -v llvm-ranlib 2>/dev/null || true)" || missing=1
show_tool llvm-tblgen \
  "$SWIFT_ROOT/usr/bin/llvm-tblgen" "$(command -v llvm-tblgen 2>/dev/null || true)" || missing=1
show_tool clang-tblgen \
  "$SWIFT_ROOT/usr/bin/clang-tblgen" "$(command -v clang-tblgen 2>/dev/null || true)" || missing=1

section "Mach-O linker smoke-test readiness"
if [[ -n "$IOS_SDK" && -x "$SWIFT_ROOT/usr/bin/clang" && -x "$SWIFT_ROOT/usr/bin/ld.lld" ]]; then
  echo "SDK + clang + lld present: yes"
  echo "candidate target: arm64-apple-ios16.0"
else
  echo "SDK + clang + lld present: no"
fi

section "source-build estimate"
echo "The Swift frontend engine requires Swift + Clang + LLVM compiler libraries."
echo "We will build only the required frontend dependency graph, not the full toolchain/tests/stdlib."
echo "Immediate/JIT mode will be disabled; this port only needs AOT compilation."

section "result"
if [[ -z "$IOS_SDK" ]]; then
  echo "BLOCKED: iPhoneOS SDK not found."
elif [[ $missing -ne 0 ]]; then
  echo "PARTIAL: one or more native build tools are missing."
  echo "Most important are llvm-tblgen and clang-tblgen; cross-compiles need host-runnable table generators."
else
  echo "READY: host tools + iPhoneOS SDK are present for an arm64 iOS compiler-engine cross-build experiment."
fi
