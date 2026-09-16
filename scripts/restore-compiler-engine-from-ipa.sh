#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
ENGINE="$WORK_ROOT/package/libXToolCompilerEngine.dylib"
STAMP="$WORK_ROOT/.xtool-compiler-engine-rev"
REVISION="clang-lld-swiftmodules-v6"
KNOWN_GOOD_SHA256="5a5d08891aa712661eb602296e4d64acb41b67c0bbccb12c2cd9d9ab186aabfa"
MEMBER="Payload/XToolMobileApp.app/Frameworks/libXToolCompilerEngine.dylib"

mkdir -p "$(dirname "$ENGINE")"

python3 - "$ROOT" "$ENGINE" "$STAMP" "$REVISION" "$KNOWN_GOOD_SHA256" "$MEMBER" "${1:-}" <<'PY'
from __future__ import annotations

from pathlib import Path
import hashlib
import os
import struct
import sys
import tempfile
import zipfile

root = Path(sys.argv[1])
engine = Path(sys.argv[2])
stamp = Path(sys.argv[3])
revision = sys.argv[4]
known_good_sha = sys.argv[5].lower()
member = sys.argv[6]
explicit = sys.argv[7]


def valid_macho_dylib(path: Path) -> tuple[bool, str]:
    try:
        with path.open("rb") as fh:
            header = fh.read(16)
    except OSError as exc:
        return False, str(exc)
    if len(header) < 16:
        return False, "file is too small"
    if header[:4] != bytes.fromhex("cffaedfe"):
        return False, f"unexpected Mach-O magic {header[:4].hex()}"
    cpu_type = struct.unpack_from("<I", header, 4)[0]
    file_type = struct.unpack_from("<I", header, 12)[0]
    if cpu_type != 0x0100000C:
        return False, f"unexpected CPU type 0x{cpu_type:08x} (expected arm64)"
    if file_type != 0x6:
        return False, f"unexpected Mach-O file type {file_type} (expected MH_DYLIB)"
    return True, "arm64 Mach-O dylib"


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


candidates: list[Path] = []
if explicit:
    candidates.append(Path(explicit).expanduser())
else:
    artifacts = root / "Artifacts"
    if artifacts.is_dir():
        candidates.extend(sorted(artifacts.glob("*.ipa"), key=lambda p: p.stat().st_mtime, reverse=True))
        candidates.extend(sorted(artifacts.glob("*/*.ipa"), key=lambda p: p.stat().st_mtime, reverse=True))

if not candidates:
    print("No backup IPA found. Put a known-good XToolMobileApp IPA under Artifacts/ or pass its path explicitly.")
    raise SystemExit(1)

seen: set[Path] = set()
for ipa in candidates:
    try:
        ipa = ipa.resolve()
    except OSError:
        pass
    if ipa in seen:
        continue
    seen.add(ipa)
    if not ipa.is_file():
        print(f"Skipping missing IPA: {ipa}")
        continue

    print(f"Checking backup IPA: {ipa}")
    try:
        with zipfile.ZipFile(ipa) as archive:
            try:
                info = archive.getinfo(member)
            except KeyError:
                print(f"  skip: missing {member}")
                continue
            if info.file_size <= 0:
                print("  skip: embedded compiler engine is empty")
                continue

            with tempfile.NamedTemporaryFile(
                prefix="libXToolCompilerEngine.", suffix=".dylib", delete=False, dir=engine.parent
            ) as tmp:
                tmp_path = Path(tmp.name)
                with archive.open(info) as src:
                    while True:
                        block = src.read(1024 * 1024)
                        if not block:
                            break
                        tmp.write(block)
    except (OSError, zipfile.BadZipFile, RuntimeError) as exc:
        print(f"  skip: unreadable/corrupt IPA ({exc})")
        continue

    try:
        ok, description = valid_macho_dylib(tmp_path)
        if not ok:
            print(f"  skip: extracted engine is invalid ({description})")
            tmp_path.unlink(missing_ok=True)
            continue

        sha = digest(tmp_path)
        size = tmp_path.stat().st_size
        if sha != known_good_sha:
            print(f"  skip: engine SHA-256 {sha} does not match known-good backup {known_good_sha}")
            tmp_path.unlink(missing_ok=True)
            continue

        os.chmod(tmp_path, 0o755)
        os.replace(tmp_path, engine)
        stamp.write_text(revision + "\n")
        print(f"Recovered compiler engine: {engine}")
        print(f"Engine format: {description}")
        print(f"Engine size: {size} bytes")
        print(f"Engine SHA-256: {sha}")
        print(f"Engine revision stamp: {revision}")
        raise SystemExit(0)
    finally:
        if tmp_path.exists() and tmp_path != engine:
            tmp_path.unlink(missing_ok=True)

print("No known-good compiler engine could be recovered from the available IPA files.")
raise SystemExit(1)
PY
