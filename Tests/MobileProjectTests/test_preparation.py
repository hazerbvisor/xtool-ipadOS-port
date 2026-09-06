import importlib.util
import json
from pathlib import Path
import struct
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/prepare-mobile-project.py'
spec = importlib.util.spec_from_file_location('prepare_mobile_project', SCRIPT)
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='xtool preparation ')
        self.root = Path(self.temp.name)
        self.project = self.root / 'project'
        self.build = self.project / '.build/arm64-apple-ios/debug'
        self.sdk = self.root / 'iPhoneOS26.5.sdk'
        self.resources = self.root / 'swift'
        self.output = self.root / 'export'
        for path in [self.build, self.sdk, self.resources, self.output]:
            path.mkdir(parents=True)
        self.inputs = prepare.Inputs(self.output, self.project, self.build, self.sdk, self.resources)

    def tearDown(self):
        self.temp.cleanup()

    def test_dependency_closure_and_cycle(self):
        commands = {name: {} for name in ['App', 'A', 'B', 'Unused']}
        self.assertEqual(prepare.dependency_order('App', commands, {'App': ['A', 'B'], 'B': ['A']}), ['A', 'B', 'App'])
        with self.assertRaisesRegex(ValueError, 'cycle'):
            prepare.dependency_order('App', commands, {'App': ['A'], 'A': ['App']})
        with self.assertRaisesRegex(ValueError, 'No Swift'):
            prepare.dependency_order('Missing', commands, {})

    def test_relocates_paths_and_removes_host_outputs(self):
        source = self.project / 'Hello.swift'
        source.write_text('func hello() {}')
        flags = prepare.frontend_flags([
            '-frontend', '-c', str(source), '-target', 'arm64-apple-ios16.0',
            '-sdk', str(self.sdk), '-o', '/tmp/old.o', '-module-cache-path', '/old/cache',
            '-I', str(self.build / 'Modules'), '-I', str(self.resources / 'iphoneos'),
            '-Xcc', '-isysroot', '-Xcc', str(self.sdk), '-swift-version', '6',
            '-entry-point-function-name', 'App_main', '-D', 'FEATURE',
        ], [source], self.inputs)
        self.assertEqual(flags, ['-I', '${BUILD}/Modules', '-I', '${SWIFT_RESOURCES}/iphoneos',
                                 '-Xcc', '-isysroot', '-Xcc', '${SDK}/.', '-swift-version', '6', '-D', 'FEATURE'])

    def test_copies_relative_and_absolute_module_headers(self):
        headers = self.project / 'headers'
        headers.mkdir()
        (headers / 'relative.h').write_text('int relative(void);')
        absolute = self.project / 'absolute.h'
        absolute.write_text('int absolute(void);')
        modulemap = headers / 'module.modulemap'
        modulemap.write_text(f'module Test {{ header "relative.h" header "{absolute}" export * }}')
        relative = self.inputs.copy(modulemap)
        self.inputs.finish_modulemaps()
        output = self.output / relative
        text = output.read_text()
        self.assertNotIn(str(self.project), text)
        self.assertTrue((output.parent / 'relative.h').is_file())
        self.assertTrue((output.parent / '../absolute.h').is_file())

    def test_rejects_runtime_plugin_and_missing_input(self):
        with self.assertRaisesRegex(ValueError, 'unsupported runtime'):
            prepare.frontend_flags(['-load-plugin-executable', '/host/macro#Macro'], [], self.inputs)
        with self.assertRaisesRegex(ValueError, 'missing'):
            self.inputs.copy(self.project / 'missing.swift')

    def test_reads_macho_library_dependencies(self):
        name = b'/System/Library/Frameworks/SwiftUI.framework/SwiftUI\0'
        command = struct.pack('<6I', 0xc, 24 + len(name), 24, 0, 0, 0) + name
        binary = self.root / 'App'
        binary.write_bytes(struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, len(command), 0, 0) + command)
        self.assertEqual(prepare.macho_dependencies(binary), [name[:-1].decode()])
        binary.write_bytes(b'not a Mach-O')
        with self.assertRaisesRegex(ValueError, 'header'):
            prepare.macho_dependencies(binary)

    def test_cli_exports_sources_generated_resources_and_native_objects(self):
        source = self.project / 'Sources/App.swift'
        source.parent.mkdir()
        source.write_text('@main struct App {}')
        native = self.build / 'Native.build/Native.c.o'
        native.parent.mkdir()
        native.write_bytes(b'native object')
        swift_object = self.build / 'App.build/App.swift.o'
        swift_object.parent.mkdir()
        swift_object.write_bytes(b'swift object')
        product = self.build / 'App.product'
        product.mkdir()
        (product / 'Objects.LinkFileList').write_text(shlex.join([str(native), str(swift_object)]))
        (self.build / 'App').write_bytes(struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 0, 0, 0, 0))
        bundle = self.build / 'App_Data.bundle'
        bundle.mkdir()
        (bundle / 'message.txt').write_text('hello')
        arguments = ['-target', 'arm64-apple-ios16.0', '-sdk', str(self.sdk), '-resource-dir', str(self.resources)]
        description = {'swiftCommands': {'App': {'moduleName': 'App', 'sources': [str(source)],
            'objects': [str(swift_object)], 'otherArguments': arguments, 'isLibrary': False}}, 'targetDependencyMap': {'App': []}}
        (self.build / 'description.json').write_text(json.dumps(description))
        self.output.rmdir()
        def run(command, cwd):
            return str(self.build) if '--show-bin-path' in command else 'Swift version 6.3.2'
        def driver(command, **kwargs):
            frontend = ['/host/swift-frontend', '-frontend', '-c', str(source)] + arguments
            return subprocess.CompletedProcess(command, 0, shlex.join(frontend), '')
        argv = ['prepare-mobile-project.py', '--project', str(self.project), '--product', 'App', '--skip-build', '--output', str(self.output)]
        with patch.object(sys, 'argv', argv), patch.object(prepare, 'run', run), patch.object(prepare.subprocess, 'run', driver):
            prepare.main()
        exported = json.loads((self.output / 'xtool-mobile.json').read_text())
        self.assertEqual(len(exported['targets']), 1)
        self.assertEqual(len(exported['linkFiles']), 1)
        self.assertTrue(exported['linkFiles'][0].endswith('Native.c.o'))
        self.assertTrue((self.output / exported['targets'][0]['sources'][0]).is_file())
        self.assertTrue((self.output / exported['resources'][0]['path'] / 'message.txt').is_file())
        self.assertNotIn(str(self.project), json.dumps(exported))


if __name__ == '__main__':
    unittest.main()
