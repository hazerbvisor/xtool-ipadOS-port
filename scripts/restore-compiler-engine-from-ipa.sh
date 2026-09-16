#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
ENGINE="$WORK_ROOT/package/libXToolCompilerEngine.dylib"
STAMP="$WORK_ROOT/.xtool-compiler-engine-rev"
REVISION="clang-lld-swiftmodules-v6"
KNOWN_GOOD_SHA256="5a5d08891aa712661eb602296e4d64acb41b67c0bbccb12c2cd9d9ab186aabfa"
IPA_MEMBER="Payload/XToolMobileApp.app/Frameworks/libXToolCompilerEngine.dylib"
REPO_ZIP="$ROOT/Artifacts/compiler-engine/libXToolCompilerEngine.dylib.zip"

mkdir -p "$(dirname "$ENGINE")"

python3 - "$ROOT" "$ENGINE" "$STAMP" "$REVISION" "$KNOWN_GOOD_SHA256" "$IPA_MEMBER" "$REPO_ZIP" "${1:-}" <<'PY'
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
ipa_member = sys.argv[6]
repo_zip = Path(sys.argv[7])
explicit = sys.argv[8]


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


def install_temp(tmp_path: Path, source_label: str) -> bool:
    ok, description = valid_macho_dylib(tmp_path)
    if not ok:
        print(f"  skip: extracted engine is invalid ({description})")
        return False

    sha = digest(tmp_path)
    size = tmp_path.stat().st_size
    if sha != known_good_sha:
        print(f"  skip: engine SHA-256 {sha} does not match known-good backup {known_good_sha}")
        return False

    os.chmod(tmp_path, 0o755)
    os.replace(tmp_path, engine)
    stamp.write_text(revision + "\n")
    print(f"Recovered compiler engine from {source_label}: {engine}")
    print(f"Engine format: {description}")
    print(f"Engine size: {size} bytes")
    print(f"Engine SHA-256: {sha}")
    print(f"Engine revision stamp: {revision}")
    return True


def extract_zip_member(archive_path: Path, members: list[str], source_label: str) -> bool:
    if not archive_path.is_file():
        return False
    print(f"Checking compiler engine backup: {archive_path}")
    try:
        with zipfile.ZipFile(archive_path) as archive:
            names = archive.namelist()
            selected = next((m for m in members if m in names), None)
            if selected is None:
                selected = next((n for n in names if Path(n).name == "libXToolCompilerEngine.dylib"), None)
            if selected is None:
                print("  skip: compiler engine dylib not found in archive")
                return False
            info = archive.getinfo(selected)
            if info.file_size <= 0:
                print("  skip: embedded compiler engine is empty")
                return False
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
        print(f"  skip: unreadable/corrupt archive ({exc})")
        return False

    try:
        return install_temp(tmp_path, source_label)
    finally:
        if tmp_path.exists() and tmp_path != engine:
            tmp_path.unlink(missing_ok=True)


# Explicit archive path wins when supplied.
if explicit:
    path = Path(explicit).expanduser()
    members = [ipa_member] if path.suffix.lower() == ".ipa" else ["libXToolCompilerEngine.dylib"]
    if extract_zip_member(path, members, str(path)):
        raise SystemExit(0)
    raise SystemExit(1)

# Preferred path: a compressed backup tracked with the repository.
if extract_zip_member(repo_zip, ["libXToolCompilerEngine.dylib"], "repo backup ZIP"):
    raise SystemExit(0)

# Fallback path: recover from any known-good XTool IPA under Artifacts/.
candidates: list[Path] = []
artifacts = root / "Artifacts"
if artifacts.is_dir():
    candidates.extend(sorted(artifacts.glob("*.ipa"), key=lambda p: p.stat().st_mtime, reverse=True))
    candidates.extend(sorted(artifacts.glob("*/*.ipa"), key=lambda p: p.stat().st_mtime, reverse=True))

for ipa in candidates:
    if extract_zip_member(ipa, [ipa_member], str(ipa)):
        raise SystemExit(0)

print("No known-good compiler engine backup found in the repo ZIP or Artifacts/ IPAs.")
raise SystemExit(1)
PY
