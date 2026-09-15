#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/Sources/XToolMobileCore/MobileProjectBuilder.swift"

python3 - "$FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = '''                    if let clang = sdk.clangBuiltinHeaders {
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

new = '''                    // Match Apple's Clang C++ header search order. libc++ must come
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

if new in text:
    print("Mobile C++ header order already fixed.")
    raise SystemExit(0)

count = text.count(old)
if count != 1:
    raise SystemExit(f"Expected exactly one native Clang header-order block, found {count}; refusing to patch.")

path.write_text(text.replace(old, new, 1))
print(f"Patched {path}")
print("C++ order is now: libc++ -> Clang builtin headers -> SDK C headers -> frameworks")
PY
