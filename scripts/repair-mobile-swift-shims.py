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
    if destination.exists() and not destination.is_dir():
        raise ValueError(f"Swift shim destination is not a directory: {destination}")
    files = set(destination.glob("*.h")) | {destination / "module.modulemap", destination / "Visibility.h"}
    # Some Darwin exports omit the entire toolchain shims directory. Include
    # the donor's complete text-header tree, not just Visibility.h: the module
    # map imports other shim headers too. Preflight before creating the folder.
    donor = next((root for root in sources
                  if usable(root / "Visibility.h") and usable(root / "module.modulemap")), None)
    if donor is not None:
        files.update(destination / path.relative_to(donor)
                     for path in donor.rglob("*") if path.is_file())
    for target in sorted(files):
        if usable(target):
            continue
        relative = target.relative_to(destination)
        source = next((root / relative for root in sources if usable(root / relative)), None)
        if source is None:
            raise ValueError(f"Invalid Swift shim {target}; no valid matching-toolchain replacement")
        pending.append((target, source.read_bytes()))
    for target, data in pending:
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(dir=target.parent, prefix=".xtool-shim-")
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
