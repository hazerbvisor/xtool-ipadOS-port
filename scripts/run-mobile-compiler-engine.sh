#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-configure}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
SHIM_DIR="$WORK_ROOT/native-tools/bin"
LOG_FILE="$WORK_ROOT/${MODE}.log"

mkdir -p "$SHIM_DIR" "$WORK_ROOT"

find_tool() {
  local exact="$1"
  local pattern="$2"
  local candidate=""

  for candidate in \
    "/opt/swift/usr/bin/$exact" \
    "/usr/bin/$exact" \
    "/data/data/com.termux/files/usr/bin/$exact" \
    "$(command -v "$exact" 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  candidate="$(find /opt/swift/usr/bin /usr/bin /data/data/com.termux/files/usr/bin \
    -maxdepth 1 \( -type f -o -type l \) -name "$pattern" 2>/dev/null \
    | sort -V | tail -1 || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  return 1
}

LIBTOOL="$(find_tool llvm-libtool-darwin 'llvm-libtool-darwin*' || true)"
if [[ -z "$LIBTOOL" ]]; then
  cat >&2 <<'EOF'
error: Darwin-compatible libtool not found.
Swift's arm64-apple-ios static-library step requires llvm-libtool-darwin.

Inside Debian, install LLVM tools with:
  apt update
  apt install -y llvm

Then rerun this command.
EOF
  exit 1
fi

ln -sfn "$LIBTOOL" "$SHIM_DIR/libtool"
ln -sfn "$LIBTOOL" "$SHIM_DIR/llvm-libtool-darwin"

INSTALL_NAME_TOOL="$(find_tool llvm-install-name-tool 'llvm-install-name-tool*' || true)"
if [[ -n "$INSTALL_NAME_TOOL" ]]; then
  ln -sfn "$INSTALL_NAME_TOOL" "$SHIM_DIR/install_name_tool"
  ln -sfn "$INSTALL_NAME_TOOL" "$SHIM_DIR/llvm-install-name-tool"
fi

for name in llvm-tblgen clang-tblgen llvm-ar llvm-ranlib llvm-config llvm-profdata; do
  tool="$(find_tool "$name" "$name*" || true)"
  if [[ -n "$tool" ]]; then
    ln -sfn "$tool" "$SHIM_DIR/$name"
  fi
done

printf 'Darwin cross-build shims:\n'
printf '  libtool:           %s\n' "$LIBTOOL"
printf '  install_name_tool: %s\n' "${INSTALL_NAME_TOOL:-not found (main script will validate)}"
printf '  PATH prefix:       %s\n' "$SHIM_DIR"
printf '  mode:              %s\n' "$MODE"
printf '  full log:          %s\n\n' "$LOG_FILE"

cd "$ROOT"

run_engine() {
  if [[ "$MODE" == "configure" ]]; then
    echo '=== prepare + iOS compatibility patches ==='
    env PATH="$SHIM_DIR:$PATH" bash scripts/build-mobile-compiler-engine.sh prepare
    bash scripts/patch-mobile-compiler-ios-sources.sh
    bash scripts/patch-mobile-compiler-sdk-macro-declarations.sh
    echo
  fi

  # SwiftCompilerSources is built by a custom Swift command that does not
  # inherit CMAKE_Swift_FLAGS. Apply this on both fresh configuration and
  # incremental build retries so the Linux-hosted swiftc always sees the
  # extracted Darwin Swift resources/SwiftShims while targeting iPhoneOS.
  if [[ "$MODE" == "configure" || "$MODE" == "build" ]]; then
    echo '=== SwiftCompilerSources Darwin SDK patch ==='
    bash scripts/patch-mobile-swift-compiler-sources-sdk.sh
    echo
  fi

  env PATH="$SHIM_DIR:$PATH" bash scripts/build-mobile-compiler-engine.sh "$MODE"
}

set +e
run_engine 2>&1 | tee "$LOG_FILE"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
  printf '\nCompiler-engine %s failed (exit %d). Full terminal output saved to:\n  %s\n' "$MODE" "$status" "$LOG_FILE" >&2
fi

exit "$status"
