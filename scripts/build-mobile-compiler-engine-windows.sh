#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_SCRIPT="$REPO_ROOT/scripts/build-mobile-compiler-engine.sh"
GENERATED_SCRIPT="$REPO_ROOT/scripts/.build-mobile-compiler-engine-windows.generated.sh"

cleanup() {
  rm -f "$GENERATED_SCRIPT"
}
trap cleanup EXIT INT TERM

[[ -f "$BASE_SCRIPT" ]] || {
  echo "error: base compiler-engine script not found: $BASE_SCRIPT" >&2
  exit 1
}

python3 - "$BASE_SCRIPT" "$GENERATED_SCRIPT" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
text = source.read_text()

old = "    -DLLVM_TARGETS_TO_BUILD=AArch64 \\\n"
new = "    -DLLVM_TARGETS_TO_BUILD=\"AArch64;X86\" \\\n"

if old not in text:
    raise SystemExit("error: expected LLVM_TARGETS_TO_BUILD=AArch64 line was not found")

text = text.replace(old, new, 1)
text = text.replace(
    '  echo "Clang + LLD:        enabled in the base LLVM graph"\n',
    '  echo "Clang + LLD:        enabled; Windows probe adds X86 + COFF"\n'
    '  echo "LLVM codegen:        AArch64 + X86"\n',
    1,
)
destination.write_text(text)
PY

chmod +x "$GENERATED_SCRIPT"
echo "Windows compiler-engine mode: LLVM targets AArch64 + X86; LLD Mach-O + COFF"
bash "$GENERATED_SCRIPT" "$@"
