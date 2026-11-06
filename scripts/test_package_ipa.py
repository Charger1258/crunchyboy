import os
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile
from package_ipa import package


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        self.app = self.root / 'StreamAnime.app'
        self.app.mkdir()
        (self.app / 'StreamAnime').write_bytes(b'fixture')
        (self.app / 'StreamAnime').chmod(0o755)
        self.info('iPhoneOS')
        self.output = self.root / 'artifacts' / 'StreamAnime.ipa'

    def tearDown(self):
        self.folder.cleanup()

    def info(self, platform):
        (self.app / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleSupportedPlatforms': [platform], 'CFBundleExecutable': 'StreamAnime'}))

    def test_device_payload_and_checksum(self):
        package(self.app, self.output)
        with zipfile.ZipFile(self.output) as archive:
            self.assertIn('Payload/StreamAnime.app/Info.plist', archive.namelist())
            self.assertIn('Payload/StreamAnime.app/StreamAnime', archive.namelist())
            self.assertTrue(all(x.startswith('Payload/') for x in archive.namelist()))
        self.assertTrue(self.output.with_suffix('.sha256').exists())

    def test_rejects_simulator(self):
        self.info('iPhoneSimulator')
        with self.assertRaises(ValueError):
            package(self.app, self.output)
        self.assertFalse(self.output.exists())

    def test_rejects_missing_executable(self):
        (self.app / 'StreamAnime').unlink()
        with self.assertRaises(ValueError):
            package(self.app, self.output)

    @unittest.skipIf(os.name == 'nt', 'Symlink creation requires Windows developer privileges')
    def test_rejects_link_outside_application(self):
        outside = self.root / 'private.txt'
        outside.write_text('must not be packaged')
        (self.app / 'escape').symlink_to(outside)
        with self.assertRaises(ValueError):
            package(self.app, self.output)
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
