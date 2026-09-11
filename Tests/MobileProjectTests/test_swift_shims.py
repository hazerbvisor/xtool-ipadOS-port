import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("repair", ROOT / "scripts/repair-mobile-swift-shims.py")
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class SwiftShimRepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dest = Path(self.temp.name) / "sdk"
        self.source = Path(self.temp.name) / "toolchain"
        self.dest.mkdir()
        self.source.mkdir()
        for folder in [self.dest, self.source]:
            (folder / "Visibility.h").write_text("#define SWIFT_RUNTIME_STDLIB_API extern\n")
            (folder / "module.modulemap").write_text('module SwiftShims { header "Visibility.h" }\n')

    def test_canary_repaired_and_second_pass_unchanged(self):
        target = self.dest / "Visibility.h"
        target.write_bytes(b"NULLcanary" + b"\0" * 10800)
        self.assertEqual(repair.repair(self.dest, [self.source]), 1)
        self.assertEqual(target.read_bytes(), (self.source / target.name).read_bytes())
        self.assertEqual(repair.repair(self.dest, [self.source]), 0)

    def test_missing_required_header_restored(self):
        (self.dest / "Visibility.h").unlink()
        self.assertEqual(repair.repair(self.dest, [self.source]), 1)

    def test_unrepairable_header_does_not_partially_modify_directory(self):
        (self.dest / "Visibility.h").write_bytes(b"NULLcanary\0")
        (self.dest / "ZMissing.h").write_bytes(b"\0")
        with self.assertRaisesRegex(ValueError, "ZMissing.h"):
            repair.repair(self.dest, [self.source])
        self.assertEqual((self.dest / "Visibility.h").read_bytes(), b"NULLcanary\0")

    def test_valid_sdk_header_preserved(self):
        target = self.dest / "Visibility.h"
        target.write_text("// valid SDK-specific header\n")
        self.assertEqual(repair.repair(self.dest, [self.source]), 0)
        self.assertEqual(target.read_text(), "// valid SDK-specific header\n")

    def test_invalid_donor_rejected(self):
        for folder in [self.dest, self.source]:
            (folder / "Visibility.h").write_bytes(b"NULLcanary\0")
        with self.assertRaisesRegex(ValueError, "no valid"):
            repair.repair(self.dest, [self.source])


if __name__ == "__main__":
    unittest.main()
