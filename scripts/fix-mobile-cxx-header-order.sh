#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/Sources/XToolMobileCore/MobileProjectBuilder.swift"

python3 - "$FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
changed = False

old_order = '''                    if let clang = sdk.clangBuiltinHeaders {
                        args += [
                            "-resource-dir", clang.deletingLastPathComponent().path,
                            "-internal-isystem", clang.path,
                        ]
                    }
                    args += [
                        "-internal-isystem", sdk.sdkURL.appendingPathComponent("usr/include").path,
                        "-iframework", sdk.sdkURL.appendingPathComponent("System/Library/Frameworks").path,
                    ]
                    if language.contains("++") {
                        args += [
                            "-std=c++17",
                            "-fcxx-exceptions",
                            "-fexceptions",
                            "-internal-isystem", sdk.sdkURL.appendingPathComponent("usr/include/c++/v1").path,
                        ]
                    }
'''

fixed_order = '''                    // Match Apple's Clang C++ header search order. libc++ must come
                    // before Clang's builtin wrappers and the SDK C headers because
                    // libc++ C-compatibility wrappers use #include_next to reach them.
                    if language.contains("++") {
                        args += [
                            "-std=c++17",
                            "-fcxx-exceptions",
                            "-fexceptions",
                            "-internal-isystem", sdk.sdkURL.appendingPathComponent("usr/include/c++/v1").path,
                        ]
                    }
                    if let clang = sdk.clangBuiltinHeaders {
                        args += [
                            "-resource-dir", clang.deletingLastPathComponent().path,
                            "-internal-isystem", clang.path,
                        ]
                    }
                    args += [
                        "-internal-isystem", sdk.sdkURL.appendingPathComponent("usr/include").path,
                        "-iframework", sdk.sdkURL.appendingPathComponent("System/Library/Frameworks").path,
                    ]
'''

# Detect the semantic header order rather than depending on exact comments.
libcxx_marker = '"-internal-isystem", sdk.sdkURL.appendingPathComponent("usr/include/c++/v1").path,'
builtin_marker = '"-resource-dir", clang.deletingLastPathComponent().path,'
sdk_c_marker = '"-internal-isystem", sdk.sdkURL.appendingPathComponent("usr/include").path,'
libcxx_pos = text.find(libcxx_marker)
builtin_pos = text.find(builtin_marker)
sdk_c_pos = text.find(sdk_c_marker)
header_order_fixed = 0 <= libcxx_pos < builtin_pos < sdk_c_pos

if not header_order_fixed:
    count = text.count(old_order)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one native Clang header-order block, found {count}; refusing to patch."
        )
    text = text.replace(old_order, fixed_order, 1)
    changed = True
    print("Fixed mobile C++ header search order.")
else:
    print("Mobile C++ header order already fixed.")

# XTool invokes Clang's frontend directly rather than the normal clang driver.
# The driver normally asks Clang to advertise GCC compatibility macros. Apple
# SDK headers depend on those macros; without them sys/cdefs.h treats the
# compiler as unsupported and strict C++ can set __DARWIN_NO_LONG_LONG=1,
# hiding lldiv_t/lldiv from libc++.
gnuc_flag = '                            "-fgnuc-version=4.2.1",\n'
if gnuc_flag not in text:
    old_args = '''                        "-pic-level", "2",
                        "-fblocks",
                        "-O0",
'''
    new_args = '''                        "-pic-level", "2",
                        "-fblocks",
                        // Match the normal Clang driver's Darwin/GCC compatibility
                        // macros (__GNUC__, __GNUG__, etc.) for Apple SDK headers.
                        "-fgnuc-version=4.2.1",
                        "-O0",
'''
    count = text.count(old_args)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one native Clang argument block, found {count}; refusing to patch."
        )
    text = text.replace(old_args, new_args, 1)
    changed = True
    print("Enabled Clang GNU compatibility macros with -fgnuc-version=4.2.1.")
else:
    print("Clang GNU compatibility macros already enabled.")

if changed:
    path.write_text(text)
    print(f"Patched {path}")
else:
    print("No changes needed.")

print("Native Clang compatibility: libc++ -> builtin headers -> SDK C headers; GNU macros 4.2.1")
PY
