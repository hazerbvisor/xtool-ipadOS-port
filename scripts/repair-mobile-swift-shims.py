#!/usr/bin/env python3
"""Restore stripped shim files from the matching Swift toolchain before packaging."""
import argparse
from pathlib import Path
import os
import tempfile


def usable(path):
    try:
        data = path.read_bytes()
        return bool(data.strip()) and b"\0" not in data and b"NULLcanary" not in data and bool(data.decode("utf-8"))
    except (OSError, UnicodeError):
        return False


def repair(destination, sources):
    # Preflight the complete directory before writing any replacement.
    pending = []
    if not destination.is_dir():
        raise ValueError(f"Missing Swift shim directory: {destination}")
    files = set(destination.glob("*.h")) | {destination / "module.modulemap", destination / "Visibility.h"}
    for target in sorted(files):
        if usable(target):
            continue
        source = next((root / target.name for root in sources if usable(root / target.name)), None)
        if source is None:
            raise ValueError(f"Invalid Swift shim {target}; no valid matching-toolchain replacement")
        pending.append((target, source.read_bytes()))
    for target, data in pending:
        fd, temporary = tempfile.mkstemp(dir=destination, prefix=".xtool-shim-")
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
            os.chmod(temporary, 0o644)
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        print(f"Restored Swift shim: {target}")
    return len(pending)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("sources", type=Path, nargs="+")
    args = parser.parse_args()
    try:
        repair(args.destination, args.sources)
    except ValueError as error:
        parser.exit(1, f"error: {error}\n")
