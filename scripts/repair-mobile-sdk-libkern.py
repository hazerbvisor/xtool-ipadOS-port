#!/usr/bin/env python3
"""Repair stripped/missing libkern headers in an XTool iPhoneOS SDK.

This is intended to run inside Termux/proot (Debian, Ubuntu, etc.). It prefers
headers already present in the same iPhoneOS SDK, then falls back to a matching
donor iPhoneOS SDK. It never invents Apple SDK declarations.

A common stripped-SDK failure is loss of the libkern/machine architecture alias.
On arm64 iPhoneOS, libkern/OSByteOrder.h may reference
<libkern/machine/OSByteOrder.h> while the actual architecture implementation is
still available as <libkern/arm/OSByteOrder.h>. In that case this repair copies
the existing ARM implementation into the missing machine path so archived
runtimes do not depend on preserving directory symlinks.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import sys
from typing import NoReturn

REQUIRED_SENTINEL = Path("usr/include/libkern/machine/OSByteOrder.h")
ARM_SENTINEL = Path("usr/include/libkern/arm/OSByteOrder.h")
REPAIR_ROOT = Path("usr/include/libkern")


def die(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def sdk_identity(sdk: Path) -> tuple[str | None, str | None]:
    settings = sdk / "SDKSettings.plist"
    canonical = None
    version = None
    if settings.is_file():
        try:
            with settings.open("rb") as f:
                data = plistlib.load(f)
            canonical = data.get("CanonicalName")
            version = data.get("Version")
        except Exception:
            pass

    if version is None:
        name = sdk.name
        if name.startswith("iPhoneOS") and name.endswith(".sdk"):
            version = name[len("iPhoneOS") : -len(".sdk")] or None
    return canonical, version


def usable_file(path: Path) -> bool:
    if path.is_symlink() and not path.exists():
        return False
    if not path.is_file():
        return False
    try:
        data = path.read_bytes()
    except OSError:
        return False
    if not data or b"\x00" in data or b"NULLcanary" in data:
        return False
    return True


def copy_file(source: Path, destination: Path) -> None:
    real_source = source.resolve()
    if not real_source.is_file():
        die(f"source entry does not resolve to a regular file: {source}")

    data = real_source.read_bytes()
    if not data or b"\x00" in data or b"NULLcanary" in data:
        die(f"source header is invalid: {source}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or destination.exists():
        if destination.is_dir() and not destination.is_symlink():
            die(f"target path is unexpectedly a directory: {destination}")
        destination.unlink()

    tmp = destination.with_name(destination.name + ".xtool-repair.tmp")
    tmp.write_bytes(data)
    try:
        shutil.copymode(real_source, tmp)
    except OSError:
        pass
    os.replace(tmp, destination)


def validate_sdk_pair(target: Path, donor: Path, allow_mismatch: bool) -> None:
    target_id, target_version = sdk_identity(target)
    donor_id, donor_version = sdk_identity(donor)

    print(f"Target SDK: {target} (canonical={target_id!r}, version={target_version!r})")
    print(f"Donor SDK:  {donor} (canonical={donor_id!r}, version={donor_version!r})")

    if target_version and donor_version and target_version != donor_version and not allow_mismatch:
        die(
            f"SDK version mismatch: target {target_version}, donor {donor_version}. "
            "Use the matching iPhoneOS SDK. Pass --allow-version-mismatch only if you intentionally accept ABI risk."
        )

    if target_id and not target_id.lower().startswith("iphoneos"):
        die(f"target does not look like an iPhoneOS SDK: {target_id}")
    if donor_id and not donor_id.lower().startswith("iphoneos"):
        die(f"donor does not look like an iPhoneOS SDK: {donor_id}")


def repair_machine_alias(target: Path, donor: Path, dry_run: bool) -> int:
    """Restore machine/OSByteOrder.h from an existing arm implementation.

    Exported Apple SDKs can lose the libkern/machine symlink/alias. Prefer the
    target SDK's own ARM header, then the donor's ARM header, then the donor's
    machine header if it survived there.
    """
    destination = target / REQUIRED_SENTINEL
    if usable_file(destination):
        return 0

    candidates = [
        (target / ARM_SENTINEL, "target ARM implementation"),
        (donor / ARM_SENTINEL, "donor ARM implementation"),
        (donor / REQUIRED_SENTINEL, "donor machine implementation"),
    ]
    for source, label in candidates:
        if usable_file(source):
            print(f"REPAIR [architecture alias]: {REQUIRED_SENTINEL} <- {label}: {source}")
            if not dry_run:
                copy_file(source, destination)
            return 1

    die(
        "could not recover libkern/machine/OSByteOrder.h; neither target nor donor "
        "contains a usable libkern/arm/OSByteOrder.h or machine implementation"
    )


def repair(target: Path, donor: Path, dry_run: bool = False) -> tuple[int, int]:
    donor_root = donor / REPAIR_ROOT
    target_root = target / REPAIR_ROOT
    if not donor_root.is_dir():
        die(f"donor SDK has no {REPAIR_ROOT}: {donor_root}")

    repaired = repair_machine_alias(target, donor, dry_run)
    preserved = 0

    # Restore any other libkern files the donor actually contains. Missing
    # architecture aliases are handled independently above, so the donor does
    # not need to contain usr/include/libkern/machine itself.
    for source in sorted(donor_root.rglob("*")):
        if source.is_dir():
            continue
        relative = source.relative_to(donor_root)
        destination = target_root / relative

        if usable_file(destination):
            preserved += 1
            continue
        if not usable_file(source):
            continue

        status = "missing"
        if destination.exists() or destination.is_symlink():
            status = "broken/placeholder"
        print(f"REPAIR [{status}]: {REPAIR_ROOT / relative}")
        if not dry_run:
            copy_file(source, destination)
        repaired += 1

    return repaired, preserved


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Restore missing/broken libkern headers in an XTool iPhoneOS SDK without inventing Apple declarations."
    )
    parser.add_argument("target_sdk", type=Path, help="XTool/stripped iPhoneOS*.sdk to repair")
    parser.add_argument("donor_sdk", type=Path, help="matching iPhoneOS*.sdk used as an additional donor")
    parser.add_argument("--dry-run", action="store_true", help="show what would be repaired without writing files")
    parser.add_argument(
        "--allow-version-mismatch",
        action="store_true",
        help="allow donor/target version mismatch (not recommended)",
    )
    args = parser.parse_args()

    target = args.target_sdk.expanduser().resolve()
    donor = args.donor_sdk.expanduser().resolve()
    if not target.is_dir():
        die(f"target SDK directory does not exist: {target}")
    if not donor.is_dir():
        die(f"donor SDK directory does not exist: {donor}")

    validate_sdk_pair(target, donor, args.allow_version_mismatch)
    repaired, preserved = repair(target, donor, args.dry_run)

    target_sentinel = target / REQUIRED_SENTINEL
    if not args.dry_run and not usable_file(target_sentinel):
        die(f"repair completed but required header is still unusable: {target_sentinel}")

    action = "would repair" if args.dry_run else "repaired"
    print(f"PASS: {action} {repaired} libkern file(s); preserved {preserved} valid target file(s).")
    if not args.dry_run:
        print(f"PASS: {REQUIRED_SENTINEL} is present and usable.")
        print("Next: import the repaired runtime archive into XTool Mobile and retry WinPad.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
