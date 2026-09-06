#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
SRC_ROOT="$WORK_ROOT/src"
SWIFT_TOP="$SRC_ROOT/swift/CMakeLists.txt"
SWIFT_UUID="$SRC_ROOT/swift/cmake/modules/FindUUID.cmake"
SWIFT_BASIC="$SRC_ROOT/swift/lib/Basic/CMakeLists.txt"
SWIFT_FRONTEND_TOOL="$SRC_ROOT/swift/lib/FrontendTool/CMakeLists.txt"
SWIFT_LANG_OPTIONS="$SRC_ROOT/swift/lib/Basic/LangOptions.cpp"
SWIFT_TYPECHECK_MACROS="$SRC_ROOT/swift/lib/Sema/TypeCheckMacros.cpp"
CMARK_CMAKE="$SRC_ROOT/cmark/src/CMakeLists.txt"

[[ -f "$SWIFT_TOP" ]] || { echo "error: Swift CMakeLists.txt not found: $SWIFT_TOP" >&2; exit 1; }
[[ -f "$SWIFT_UUID" ]] || { echo "error: Swift FindUUID.cmake not found: $SWIFT_UUID" >&2; exit 1; }
[[ -f "$SWIFT_BASIC" ]] || { echo "error: Swift Basic CMakeLists.txt not found: $SWIFT_BASIC" >&2; exit 1; }
[[ -f "$SWIFT_FRONTEND_TOOL" ]] || { echo "error: Swift FrontendTool CMakeLists.txt not found: $SWIFT_FRONTEND_TOOL" >&2; exit 1; }
[[ -f "$SWIFT_LANG_OPTIONS" ]] || { echo "error: Swift LangOptions.cpp not found: $SWIFT_LANG_OPTIONS" >&2; exit 1; }
[[ -f "$SWIFT_TYPECHECK_MACROS" ]] || { echo "error: Swift TypeCheckMacros.cpp not found: $SWIFT_TYPECHECK_MACROS" >&2; exit 1; }
[[ -f "$CMARK_CMAKE" ]] || { echo "error: swift-cmark CMakeLists.txt not found: $CMARK_CMAKE" >&2; exit 1; }

python3 - "$SWIFT_TOP" "$SWIFT_UUID" "$SWIFT_BASIC" "$SWIFT_FRONTEND_TOOL" "$CMARK_CMAKE" "$SWIFT_LANG_OPTIONS" "$SWIFT_TYPECHECK_MACROS" <<'PY'
from pathlib import Path
import sys

top_file = Path(sys.argv[1])
uuid_file = Path(sys.argv[2])
basic_file = Path(sys.argv[3])
frontend_file = Path(sys.argv[4])
cmark_file = Path(sys.argv[5])
lang_options_file = Path(sys.argv[6])
typecheck_macros_file = Path(sys.argv[7])

# XTool needs Swift's compiler libraries and SwiftCompilerSources, but not the
# command-line compiler executables. Keeping SWIFT_INCLUDE_TOOLS=ON is important
# because it also enables generated compiler headers and lib/, so gate only the
# final tools/ and localization subdirectories with our private build switch.
s = top_file.read_text()
mode_line = 'set(XTOOL_FRONTEND_LIBRARY_ONLY ON CACHE BOOL "XTool mobile frontend libraries only" FORCE)'
if mode_line not in s:
    s = mode_line + '\n' + s
    print('XTool frontend library-only mode: enabled')
else:
    print('XTool frontend library-only mode: already enabled')

old_tools = '  add_subdirectory(tools)'
new_tools = '  if(NOT XTOOL_FRONTEND_LIBRARY_ONLY)\n    add_subdirectory(tools)\n  endif()'
if new_tools in s:
    print('Swift executable tools gate: already applied')
elif old_tools in s:
    s = s.replace(old_tools, new_tools, 1)
    print('Swift executable tools gate: applied')
else:
    raise SystemExit('error: expected Swift tools subdirectory line not found')

old_localization = '  if(SWIFT_NATIVE_SWIFT_TOOLS_PATH)\n'
new_localization = '  if(SWIFT_NATIVE_SWIFT_TOOLS_PATH AND NOT XTOOL_FRONTEND_LIBRARY_ONLY)\n'
anchor = new_tools
idx = s.find(anchor)
if idx < 0:
    raise SystemExit('error: Swift tools gate anchor missing')
head, tail = s[:idx], s[idx:]
if new_localization in tail:
    print('Swift localization tools gate: already applied')
elif old_localization in tail:
    tail = tail.replace(old_localization, new_localization, 1)
    s = head + tail
    print('Swift localization tools gate: applied')
else:
    raise SystemExit('error: expected Swift localization guard not found')
top_file.write_text(s)

# Swift 6.3.2 treats only CMAKE_SYSTEM_NAME=Darwin as an Apple platform.
# CMake uses CMAKE_SYSTEM_NAME=iOS for an iPhoneOS cross build, but UUID is
# supplied by the Apple SDK/libSystem and does not require Linux libuuid.
s = uuid_file.read_text()
old = 'if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")'
new = 'if(CMAKE_SYSTEM_NAME STREQUAL "Darwin" OR CMAKE_SYSTEM_NAME STREQUAL "iOS")'
if new in s:
    print('Swift UUID iOS guard: already applied')
elif old in s:
    uuid_file.write_text(s.replace(old, new, 1))
    print('Swift UUID iOS guard: applied')
else:
    raise SystemExit('error: expected Swift UUID platform check not found')

# Swift Basic has a second platform check before it even calls FindUUID.
s = basic_file.read_text()
old = 'if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")\n  set(UUID_INCLUDE "")'
new = 'if(CMAKE_SYSTEM_NAME STREQUAL "Darwin" OR CMAKE_SYSTEM_NAME STREQUAL "iOS")\n  set(UUID_INCLUDE "")'
if new in s:
    print('Swift Basic UUID iOS guard: already applied')
elif old in s:
    basic_file.write_text(s.replace(old, new, 1))
    print('Swift Basic UUID iOS guard: applied')
else:
    raise SystemExit('error: expected Swift Basic UUID platform check not found')

# Swift main has since changed to make swiftImmediate conditional. Backport that
# behaviour to 6.3.2 so an AOT-only XTool compiler does not pull MCJIT/ORC/JITLink.
s = frontend_file.read_text()
conditional = '''if (SWIFT_BUILD_IMMEDIATE_MODE)
  target_link_libraries(swiftFrontendTool PRIVATE
    swiftImmediate)
endif()'''
if conditional in s:
    print('Swift FrontendTool immediate-mode gate: already applied')
else:
    immediate_line = '    swiftImmediate\n'
    if immediate_line not in s:
        raise SystemExit('error: expected swiftImmediate link line not found')
    s = s.replace(immediate_line, '', 1)
    marker = '\nif (SWIFT_BUILD_SWIFT_SYNTAX)'
    if marker not in s:
        raise SystemExit('error: expected SwiftSyntax link marker not found')
    s = s.replace(marker, '\n' + conditional + '\n' + marker, 1)
    frontend_file.write_text(s)
    print('Swift FrontendTool immediate-mode gate: applied')

# The Apple iOS SDK's Swift module interfaces contain macro declarations even
# when the user's source never expands a macro. Keep macro syntax enabled in the
# compact AOT compiler so those declarations can be parsed/imported.
s = lang_options_file.read_text()
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
macro_disable_calls = (
    'disableFeature(Feature::Macros);',
    'disableFeature(Feature::FreestandingExpressionMacros);',
    'disableFeature(Feature::AttachedMacros);',
    'disableFeature(Feature::ExtensionMacros);',
)
if new in s:
    print('Swift SDK macro language features: already patched')
elif old in s:
    lang_options_file.write_text(s.replace(old, new, 1))
    print('Swift SDK macro language features: patched')
elif not any(call in s for call in macro_disable_calls):
    # A dedicated compatibility patch may already have replaced the same block
    # with slightly different comments. What matters semantically is that the
    # four compile-time feature-disable calls are gone.
    print('Swift SDK macro language features: already patched (semantic check)')
else:
    raise SystemExit('error: Swift macro feature-disable calls remain but expected block was not recognized')

# Without SwiftSyntax, Swift 6.3.2 otherwise diagnoses each macro declaration's
# definition as unsupported. Treat the definition as opaque/undefined so SDK
# module interfaces can load. Actual macro expansion remains unavailable.
s = typecheck_macros_file.read_text()
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
    print('Swift SDK macro-definition fallback: already patched')
elif old in s:
    typecheck_macros_file.write_text(s.replace(old, new, 1))
    print('Swift SDK macro-definition fallback: patched')
elif 'macro->diagnose(diag::macro_unsupported);' not in s and 'return MacroDefinition::forUndefined();' in s:
    print('Swift SDK macro-definition fallback: already patched (semantic check)')
else:
    raise SystemExit('error: expected Swift MacroDefinitionRequest fallback not found')

# CMake models iOS executables as bundles. swift-cmark's install rule omits a
# bundle destination, even though we never install it during this build.
s = cmark_file.read_text()
needle = '  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}\n  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}'
replacement = '  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}\n  BUNDLE DESTINATION ${CMAKE_INSTALL_BINDIR}\n  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}'
if replacement in s:
    print('swift-cmark iOS bundle install rule: already applied')
elif needle in s:
    cmark_file.write_text(s.replace(needle, replacement, 1))
    print('swift-cmark iOS bundle install rule: applied')
else:
    raise SystemExit('error: expected swift-cmark install block not found')
PY
