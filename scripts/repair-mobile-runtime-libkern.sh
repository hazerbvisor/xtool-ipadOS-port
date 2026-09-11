#!/usr/bin/env bash
set -euo pipefail

# Repair a prepared XToolMobileRuntime directory or .tar archive from Termux/proot.
# Usage:
#   ./scripts/repair-mobile-runtime-libkern.sh <runtime-dir-or-tar> <full-iPhoneOS-sdk> [output-tar]
#
# Examples:
#   ./scripts/repair-mobile-runtime-libkern.sh \
#     .build/XToolMobileRuntime \
#     ~/xcode/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk
#
#   ./scripts/repair-mobile-runtime-libkern.sh \
#     .build/XToolMobileRuntime.tar \
#     ~/xcode/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk \
#     .build/XToolMobileRuntime-fixed.tar

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPAIR="$ROOT/scripts/repair-mobile-sdk-libkern.py"
INPUT="${1:-}"
DONOR="${2:-}"
OUTPUT="${3:-}"

if [[ -z "$INPUT" || -z "$DONOR" ]]; then
  echo "usage: $0 <runtime-dir-or-tar> <full-iPhoneOS-sdk> [output-tar]" >&2
  exit 2
fi

if [[ ! -f "$REPAIR" ]]; then
  echo "error: repair helper not found: $REPAIR" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 1
fi
if [[ ! -d "$DONOR" ]]; then
  echo "error: donor SDK directory does not exist: $DONOR" >&2
  exit 1
fi

find_runtime_sdk() {
  local runtime="$1"
  local sdk_dir="$runtime/Developer/Platforms/iPhoneOS.platform/Developer/SDKs"
  if [[ ! -d "$sdk_dir" ]]; then
    echo "error: runtime has no iPhoneOS SDK directory: $sdk_dir" >&2
    return 1
  fi

  # Prefer the SDK whose basename matches the donor exactly. Xcode-style SDK
  # trees normally also contain iPhoneOS.sdk as an alias/symlink to the current
  # versioned SDK, so counting every iPhoneOS*.sdk entry as a distinct SDK is
  # incorrect.
  local donor_name exact
  donor_name="$(basename "$DONOR")"
  exact="$sdk_dir/$donor_name"
  if [[ -d "$exact" ]]; then
    printf '%s\n' "$exact"
    return 0
  fi

  # Otherwise ignore the generic iPhoneOS.sdk alias and consider only versioned
  # SDK directories (for example iPhoneOS26.5.sdk).
  local found=() candidate base
  shopt -s nullglob
  for candidate in "$sdk_dir"/iPhoneOS*.sdk; do
    base="$(basename "$candidate")"
    [[ "$base" == "iPhoneOS.sdk" ]] && continue
    [[ -d "$candidate" ]] && found+=("$candidate")
  done
  shopt -u nullglob

  if (( ${#found[@]} == 1 )); then
    printf '%s\n' "${found[0]}"
    return 0
  fi

  # Last-resort compatibility for a runtime that contains only iPhoneOS.sdk.
  if (( ${#found[@]} == 0 )) && [[ -d "$sdk_dir/iPhoneOS.sdk" ]]; then
    printf '%s\n' "$sdk_dir/iPhoneOS.sdk"
    return 0
  fi

  echo "error: could not uniquely select a versioned iPhoneOS SDK under $sdk_dir" >&2
  echo "donor basename: $donor_name" >&2
  printf '  %s\n' "${found[@]:-}" >&2
  return 1
}

repair_runtime_dir() {
  local runtime="$1"
  local sdk
  sdk="$(find_runtime_sdk "$runtime")"
  echo "Repairing runtime SDK: $sdk"
  python3 "$REPAIR" "$sdk" "$DONOR"
}

pack_runtime() {
  local runtime="$1"
  local output="$2"
  if ! command -v tar >/dev/null 2>&1; then
    echo "error: tar is required" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$output")"
  local out_dir out_abs
  out_dir="$(cd "$(dirname "$output")" && pwd)"
  out_abs="$out_dir/$(basename "$output")"
  (
    cd "$(dirname "$runtime")"
    tar --format=pax \
      --pax-option=delete=atime,delete=ctime \
      -cf "$out_abs" "$(basename "$runtime")"
  )
  echo "Created repaired runtime archive: $out_abs"
  ls -lh "$out_abs"
}

if [[ -d "$INPUT" ]]; then
  repair_runtime_dir "$INPUT"
  if [[ -n "$OUTPUT" ]]; then
    pack_runtime "$INPUT" "$OUTPUT"
  else
    echo "PASS: runtime directory repaired in place."
    echo "To create an importable archive, rerun with a third argument, for example:"
    echo "  $0 '$INPUT' '$DONOR' '${INPUT%/}-fixed.tar'"
  fi
  exit 0
fi

if [[ -f "$INPUT" ]]; then
  if ! command -v tar >/dev/null 2>&1; then
    echo "error: tar is required to repair an archive" >&2
    exit 1
  fi
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "Extracting runtime archive: $INPUT"
  tar -xf "$INPUT" -C "$tmp"

  roots=()
  shopt -s nullglob
  roots=("$tmp"/*)
  shopt -u nullglob
  if (( ${#roots[@]} != 1 )) || [[ ! -d "${roots[0]}" ]]; then
    echo "error: expected archive to contain one top-level runtime directory" >&2
    exit 1
  fi

  runtime="${roots[0]}"
  repair_runtime_dir "$runtime"
  if [[ -z "$OUTPUT" ]]; then
    OUTPUT="${INPUT%.tar}-libkern-fixed.tar"
  fi
  pack_runtime "$runtime" "$OUTPUT"
  exit 0
fi

echo "error: input runtime directory/archive does not exist: $INPUT" >&2
exit 1
