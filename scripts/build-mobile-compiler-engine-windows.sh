#!/usr/bin/env bash
set -euo pipefail

# Deprecated Phase 20 compatibility wrapper.
#
# Windows/X86 support is no longer added to the main Swift compiler engine.
# Route old commands to the isolated backend graph so this script can never
# trigger another full Swift + AArch64 + X86 compiler rebuild.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Phase 20: Windows support now uses the isolated XToolWindowsBackend dylib."
echo "Redirecting to scripts/build-mobile-windows-backend.sh ..."
exec bash "$ROOT/scripts/build-mobile-windows-backend.sh" "$@"
