#!/usr/bin/env bash
set -euo pipefail

DARWIN_ROOT="${DARWIN_SDK_ROOT:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}"
SWIFT_ROOT="${SWIFT_ROOT:-/opt/swift}"

section() {
  printf '\n=== %s ===\n' "$1"
}

show_matches() {
  local root="$1"
  if [[ ! -d "$root" ]]; then
    echo "missing: $root"
    return
  fi

  find "$root" -type f \
    \( -iname '*FrontendTool*' \
       -o -iname '*swiftFrontend*' \
       -o -iname '*swiftIRGen*' \
       -o -iname '*swiftClangImporter*' \
       -o -iname 'libLLVM*' \
       -o -iname 'libclang*' \
       -o -iname '*SwiftScan*' \) \
    2>/dev/null | sort | head -120
}

classify_matches() {
  local root="$1"
  if [[ ! -d "$root" ]]; then
    return
  fi

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    printf '%s\n  ' "$path"
    file -L "$path" 2>/dev/null || true
  done < <(
    find "$root" -type f \
      \( -iname '*FrontendTool*' \
         -o -iname '*swiftFrontend*' \
         -o -iname '*swiftIRGen*' \
         -o -iname '*swiftClangImporter*' \
         -o -iname 'libLLVM*' \
         -o -iname 'libclang*' \
         -o -iname '*SwiftScan*' \) \
      2>/dev/null | sort | head -80
  )
}

section "host"
uname -a || true
printf 'swift: '
command -v swift || true
swift --version || true
printf 'swift-frontend: '
command -v swift-frontend || true
printf 'clang: '
command -v clang || true

section "Darwin bundle candidate compiler libraries"
echo "root: $DARWIN_ROOT"
show_matches "$DARWIN_ROOT"

section "Darwin bundle file formats"
classify_matches "$DARWIN_ROOT"

section "installed Linux Swift candidate compiler libraries"
echo "root: $SWIFT_ROOT"
show_matches "$SWIFT_ROOT"

section "installed Linux Swift file formats"
classify_matches "$SWIFT_ROOT"

section "exact frontend archive search"
find "$DARWIN_ROOT" "$SWIFT_ROOT" -type f \
  \( -name 'libswiftFrontendTool.a' \
     -o -name 'libswiftFrontend.a' \
     -o -name 'libswiftIRGen.a' \
     -o -name 'libswiftClangImporter.a' \) \
  -print 2>/dev/null || true

section "Mach-O iOS platform hints"
OBJDUMP=""
for candidate in \
  "$SWIFT_ROOT/usr/bin/llvm-objdump" \
  /usr/bin/llvm-objdump \
  "$(command -v llvm-objdump 2>/dev/null || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    OBJDUMP="$candidate"
    break
  fi
done

if [[ -z "$OBJDUMP" ]]; then
  echo "llvm-objdump not found; skipping LC_BUILD_VERSION inspection"
else
  echo "using: $OBJDUMP"
  count=0
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if file -L "$path" 2>/dev/null | grep -q 'Mach-O'; then
      echo "--- $path"
      "$OBJDUMP" --macho --private-headers "$path" 2>/dev/null \
        | grep -A8 -E 'LC_BUILD_VERSION|LC_VERSION_MIN_IPHONEOS' \
        | head -20 || true
      count=$((count + 1))
      [[ $count -lt 20 ]] || break
    fi
  done < <(
    find "$DARWIN_ROOT" -type f \
      \( -iname '*Frontend*' -o -iname '*IRGen*' -o -iname '*SwiftScan*' -o -iname 'libLLVM*' \) \
      2>/dev/null | sort
  )
fi

section "result guidance"
echo "Usable in-process compiler engine requires arm64 iOS-compatible compiler libraries."
echo "ELF files are Linux-host-only. Mach-O macOS files are also not usable as iOS app code."
echo "If no iOS compiler-engine libraries appear above, the next step is cross-building Swift compiler libraries for arm64-apple-ios."
