#!/usr/bin/env bash
set -euo pipefail

# Phase 20 compiler-engine wrapper.
#
# The normal mobile engine intentionally builds only LLVM's AArch64 backend to
# keep the dylib smaller. WinPad Phase 20 also needs Clang to emit x86_64 COFF,
# so this wrapper reuses the known-good build script with X86 enabled alongside
# AArch64 without permanently changing the normal build path.

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
old = '    -DLLVM_TARGETS_TO_BUILD=AArch64 \\\n'
new = '    -DLLVM_TARGETS_TO_BUILD="AArch64;X86" \\\n'
if old not in text:
    raise SystemExit('error: expected LLVM_TARGETS_TO_BUILD=AArch64 line not found')
path.write_text(text.replace(old, new, 1))
PY
chmod +x "$GENERATED_SCRIPT"

echo "Phase 20 compiler engine: enabling LLVM targets AArch64 + X86"
echo "mode: $MODE"
bash "$GENERATED_SCRIPT" "$MODE"
