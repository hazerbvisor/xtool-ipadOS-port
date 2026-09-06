#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
TYPECHECK_DECL_PRIMARY="$WORK_ROOT/src/swift/lib/Sema/TypeCheckDeclPrimary.cpp"

[[ -f "$TYPECHECK_DECL_PRIMARY" ]] || {
  echo "error: Swift TypeCheckDeclPrimary.cpp not found: $TYPECHECK_DECL_PRIMARY" >&2
  exit 1
}

python3 - "$TYPECHECK_DECL_PRIMARY" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
old = '''    case MacroDefinition::Kind::Undefined:
      MD->diagnose(diag::macro_must_be_defined, MD->getName());
      break;
'''
new = '''    case MacroDefinition::Kind::Undefined:
#if !SWIFT_BUILD_SWIFT_SYNTAX
      // XTool Mobile compact AOT engine: Apple SDK .swiftinterface files expose
      // macro APIs even when this compiler does not bundle SwiftSyntax/plugin
      // expansion. Permit those imported declarations to remain opaque. User
      // source still diagnoses a missing macro definition below, and expansion
      // of an opaque SDK macro is intentionally unavailable in this build.
      if (auto *sourceFile = MD->getParentSourceFile();
          sourceFile && sourceFile->Kind == SourceFileKind::Interface) {
        break;
      }
#endif
      MD->diagnose(diag::macro_must_be_defined, MD->getName());
      break;
'''
if new in s:
    print('Swift SDK interface undefined-macro diagnostic gate: already applied')
elif old in s:
    p.write_text(s.replace(old, new, 1))
    print('Swift SDK interface undefined-macro diagnostic gate: applied')
else:
    raise SystemExit('error: expected Swift macro undefined diagnostic block not found')
PY
