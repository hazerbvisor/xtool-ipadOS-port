#!/usr/bin/env bash
set -euo pipefail

# Phase 20 compiler-engine wrapper.
#
# The normal mobile engine intentionally builds only LLVM's AArch64 backend to
# keep the dylib smaller. WinPad Phase 20 also needs Clang to emit x86_64 COFF,
# so this wrapper reuses the known-good build script with X86 enabled alongside
# AArch64 without permanently changing the normal build path.
#
# LLD's standalone tool target is also disabled here. The mobile compiler engine
# embeds lldCOFF/lldMachO as libraries and calls them through the stable C ABI;
# building/installing the standalone `lld` executable under CMAKE_SYSTEM_NAME=iOS
# makes CMake treat it as a MACOSX_BUNDLE and fails because no bundle destination
# is provided.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_SCRIPT="$REPO_ROOT/scripts/build-mobile-compiler-engine.sh"
GENERATED_SCRIPT="$REPO_ROOT/scripts/.build-mobile-compiler-engine-windows.generated.sh"
MODE="${1:-configure}"

[[ -f "$BASE_SCRIPT" ]] || { echo "error: missing $BASE_SCRIPT" >&2; exit 1; }

cleanup() {
  rm -f "$GENERATED_SCRIPT"
}
trap cleanup EXIT

cp "$BASE_SCRIPT" "$GENERATED_SCRIPT"
python3 - "$GENERATED_SCRIPT" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old_targets = '    -DLLVM_TARGETS_TO_BUILD=AArch64 \\\n'
new_targets = '    -DLLVM_TARGETS_TO_BUILD="AArch64;X86" \\\n'
if old_targets not in text:
    raise SystemExit('error: expected LLVM_TARGETS_TO_BUILD=AArch64 line not found')
text = text.replace(old_targets, new_targets, 1)

# LLVM_BUILD_TOOLS=OFF does not control LLD's own `lld` frontend executable.
# LLD uses its separate LLD_BUILD_TOOLS switch. Keep the driver libraries in
# the graph, but prevent CMake from installing the standalone iOS bundle target.
anchor = '    -DLLVM_BUILD_TOOLS=OFF \\\n'
injected = anchor + '    -DLLD_BUILD_TOOLS=OFF \\\n'
if anchor not in text:
    raise SystemExit('error: expected LLVM_BUILD_TOOLS=OFF line not found')
text = text.replace(anchor, injected, 1)

path.write_text(text)
PY
chmod +x "$GENERATED_SCRIPT"

echo "Phase 20 compiler engine: enabling LLVM targets AArch64 + X86"
echo "Phase 20 compiler engine: disabling standalone LLD tool (embedded drivers stay enabled)"
echo "mode: $MODE"
bash "$GENERATED_SCRIPT" "$MODE"
