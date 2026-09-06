#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
LANG_OPTIONS="$WORK_ROOT/src/swift/lib/Basic/LangOptions.cpp"
TYPECHECK_MACROS="$WORK_ROOT/src/swift/lib/Sema/TypeCheckMacros.cpp"
TYPECHECK_DECL_PRIMARY="$WORK_ROOT/src/swift/lib/Sema/TypeCheckDeclPrimary.cpp"
BUILD_ROOT="$WORK_ROOT/build-ios"
JOBS="${XTOOL_COMPILER_JOBS:-2}"

[[ -f "$LANG_OPTIONS" ]] || { echo "error: Swift LangOptions.cpp not found: $LANG_OPTIONS" >&2; exit 1; }
[[ -f "$TYPECHECK_MACROS" ]] || { echo "error: Swift TypeCheckMacros.cpp not found: $TYPECHECK_MACROS" >&2; exit 1; }
[[ -f "$TYPECHECK_DECL_PRIMARY" ]] || { echo "error: Swift TypeCheckDeclPrimary.cpp not found: $TYPECHECK_DECL_PRIMARY" >&2; exit 1; }
[[ -f "$BUILD_ROOT/build.ninja" ]] || { echo "error: existing compiler build not found: $BUILD_ROOT/build.ninja" >&2; exit 1; }

python3 - "$LANG_OPTIONS" "$TYPECHECK_MACROS" "$TYPECHECK_DECL_PRIMARY" <<'PY'
from pathlib import Path
import sys

lang_options = Path(sys.argv[1])
typecheck_macros = Path(sys.argv[2])
typecheck_decl_primary = Path(sys.argv[3])

# 1) Keep macro declaration syntax enabled even when SwiftSyntax/plugin support
# is intentionally not linked into the compact XTool AOT engine.
s = lang_options.read_text()
old = '''  // Special case: remove macro support if the compiler wasn't built with a
  // host Swift.
#if !SWIFT_BUILD_SWIFT_SYNTAX
  disableFeature(Feature::Macros);
  disableFeature(Feature::FreestandingExpressionMacros);
  disableFeature(Feature::AttachedMacros);
  disableFeature(Feature::ExtensionMacros);
#endif
'''
new = '''  // XTool Mobile AOT compatibility: keep the macro language features enabled
  // even when the SwiftSyntax/plugin implementation is not linked. Apple SDK
  // Swift interfaces contain macro declarations that must be parsed/imported,
  // even for source files that never expand or execute a macro. Actual external
  // macro expansion still requires the SwiftSyntax/plugin implementation.
#if !SWIFT_BUILD_SWIFT_SYNTAX
  // Intentionally do not disable Feature::Macros or its declaration roles.
#endif
'''
if new in s:
    print('XTool macro language-feature patch: already applied')
elif old in s:
    lang_options.write_text(s.replace(old, new, 1))
    print('XTool macro language-feature patch: applied')
else:
    raise SystemExit('error: expected Swift macro-disable block not found')

# 2) Swift 6.3.2 normally diagnoses every macro declaration as unsupported when
# SWIFT_BUILD_SWIFT_SYNTAX=OFF. For the compact AOT engine, treat those SDK macro
# definitions as opaque/undefined so the standard-library .swiftinterface can be
# imported. If user source actually attempts macro expansion, the missing macro
# implementation is still unavailable and will fail at expansion time.
s = typecheck_macros.read_text()
old = '''#else
  macro->diagnose(diag::macro_unsupported);
  return MacroDefinition::forInvalid();
#endif
'''
new = '''#else
  // XTool Mobile AOT compatibility: allow importing macro declarations from
  // Apple SDK module interfaces without bundling SwiftSyntax/plugin expansion.
  // The declaration remains visible, but its implementation is intentionally
  // unavailable in this compact compiler configuration.
  return MacroDefinition::forUndefined();
#endif
'''
if new in s:
    print('XTool macro-definition import fallback: already applied')
elif old in s:
    typecheck_macros.write_text(s.replace(old, new, 1))
    print('XTool macro-definition import fallback: applied')
else:
    raise SystemExit('error: expected Swift MacroDefinitionRequest fallback not found')

# 3) Type checking normally rejects an Undefined macro definition. That is the
# right behaviour for user source, but imported Apple .swiftinterface modules
# must remain loadable in this compact configuration. Suppress only that one
# diagnostic for SourceFileKind::Interface; normal source files still diagnose
# a missing macro definition and actual macro expansion remains unavailable.
s = typecheck_decl_primary.read_text()
old = '''    case MacroDefinition::Kind::Undefined:
      MD->diagnose(diag::macro_must_be_defined, MD->getName());
      break;
'''
new = '''    case MacroDefinition::Kind::Undefined:
#if !SWIFT_BUILD_SWIFT_SYNTAX
      if (auto *sourceFile = MD->getParentSourceFile();
          sourceFile && sourceFile->Kind == SourceFileKind::Interface) {
        break;
      }
#endif
      MD->diagnose(diag::macro_must_be_defined, MD->getName());
      break;
'''
if new in s:
    print('XTool SDK interface undefined-macro diagnostic gate: already applied')
elif old in s:
    typecheck_decl_primary.write_text(s.replace(old, new, 1))
    print('XTool SDK interface undefined-macro diagnostic gate: applied')
else:
    raise SystemExit('error: expected Swift macro undefined diagnostic block not found')
PY

echo
echo "=== incremental compiler rebuild ==="
echo "Preserving existing LLVM/Swift objects; Ninja will rebuild only affected targets."
echo "jobs: $JOBS"
XTOOL_COMPILER_JOBS="$JOBS" bash "$ROOT/scripts/run-mobile-compiler-engine.sh" build

echo
echo "SUCCESS: SDK macro import compatibility engine rebuilt incrementally."
echo "Next: bash scripts/build-xtool-mobile-one-shot.sh"
