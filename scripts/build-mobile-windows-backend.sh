#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-build}"

cat <<'EOF'
Phase 20 Windows backend changed:
  old: LLVM X86 + lldCOFF (1700+ build steps)
  new: TinyCC x86_64 PE backend (2 C objects + 1 dylib link)

The old LLVM graph is intentionally no longer started by this command.
The tracked compiler-engine backup under Artifacts/compiler-engine/ is not modified by this wrapper.
EOF

case "$MODE" in
  configure)
    echo "TinyCC needs no CMake/Ninja configure stage; preparing source/config instead."
    exec bash "$ROOT/scripts/build-mobile-windows-tcc.sh" prepare
    ;;
  prepare|build|status|clean)
    exec bash "$ROOT/scripts/build-mobile-windows-tcc.sh" "$MODE"
    ;;
  *)
    echo "usage: $0 [prepare|configure|build|status|clean]" >&2
    exit 2
    ;;
esac
