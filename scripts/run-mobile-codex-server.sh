#!/usr/bin/env bash
set -euo pipefail
# Run in a dedicated host account/container, behind a TLS WebSocket proxy.
XTOOL_CODEX_STATE="${XTOOL_CODEX_STATE:-$PWD/.build/mobile-codex}"
mkdir -p "$XTOOL_CODEX_STATE/workspace"
XTOOL_CODEX_STATE="$(cd "$XTOOL_CODEX_STATE" && pwd)"
XTOOL_CODEX_TOKEN="$XTOOL_CODEX_STATE/connection-token"
umask 077
if [ ! -f "$XTOOL_CODEX_TOKEN" ]; then
  python3 - "$XTOOL_CODEX_TOKEN" <<'PY'
import secrets, sys
with open(sys.argv[1], 'x') as token:
    token.write(secrets.token_urlsafe(48))
PY
fi
chmod 600 "$XTOOL_CODEX_TOKEN"
cd "$XTOOL_CODEX_STATE/workspace"
printf 'Token file: %s\nBind: ws://127.0.0.1:4500 (put a trusted TLS proxy in front)\n' "$XTOOL_CODEX_TOKEN"
exec "${XTOOL_CODEX_BIN:-codex}" app-server \
  -c 'features.shell_tool=false' -c 'features.unified_exec=false' \
  --listen ws://127.0.0.1:4500 --ws-auth capability-token \
  --ws-token-file "$XTOOL_CODEX_TOKEN"
