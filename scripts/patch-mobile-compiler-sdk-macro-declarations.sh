#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
LANG_OPTIONS="$WORK_ROOT/src/swift/lib/Basic/LangOptions.cpp"

[[ -f "$LANG_OPTIONS" ]] || { echo "error: Swift LangOptions.cpp not found: $LANG_OPTIONS" >&2; exit 1; }

python3 - "$LANG_OPTIONS" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
old = '''  // Special case: remove macro support if the compiler wasn't built with a
  // host Swift.
#if !SWIFT_BUILD_SWIFT_SYNTAX
  disableFeature(Feature::Macros);
  disableFeature(Feature::FreestandingExpressionMacros);
  disableFeature(Feature::AttachedMacros);
  disableFeature(Feature::ExtensionMacros);
#endif
'''
new = '''  // XTool Mobile AOT compatibility: keep macro language features enabled even
  // when SwiftSyntax/plugin execution is not linked. Apple SDK Swift interfaces
  // contain macro declarations that must be parsed/imported by ordinary AOT
  // compilations. External macro expansion still requires the plugin backend.
#if !SWIFT_BUILD_SWIFT_SYNTAX
  // Intentionally keep the promoted macro declaration features enabled.
#endif
'''

disable_markers = [
    'disableFeature(Feature::Macros);',
    'disableFeature(Feature::FreestandingExpressionMacros);',
    'disableFeature(Feature::AttachedMacros);',
    'disableFeature(Feature::ExtensionMacros);',
]

if new in s:
    print('XTool SDK macro-declaration compatibility patch: already applied')
elif not any(marker in s for marker in disable_markers):
    # Earlier XTool patch revisions used slightly different comments around the
    # same semantic change. If all four disableFeature calls are already gone,
    # the desired compiler state is present regardless of comment wording.
    print('XTool SDK macro-declaration compatibility patch: already applied (semantic check)')
elif old in s:
    p.write_text(s.replace(old, new, 1))
    print('XTool SDK macro-declaration compatibility patch: applied')
else:
    present = [marker for marker in disable_markers if marker in s]
    raise SystemExit(
        'error: Swift macro-disable block is in an unexpected partial state: '
        + ', '.join(present)
    )
PY
