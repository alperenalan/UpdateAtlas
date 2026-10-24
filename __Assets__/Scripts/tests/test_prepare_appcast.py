"""Archive validation must refuse extraction paths escaping the application."""
import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('prepare', ROOT / '__Assets__/Scripts/Apple/prepare_appcast.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

class ArchiveSafetyTests(unittest.TestCase):
    def test_release_identity_uses_domain_but_preserves_existing_signing_key(self):
        self.assertEqual(MODULE.BUNDLE_ID, 'com.alperenalan.updateatlas')
        self.assertEqual(MODULE.ACCOUNT, 'dev.alperenalan.updateatlas')
        metadata = {'CFBundleIdentifier': MODULE.BUNDLE_ID,
                    'SUPublicEDKey': MODULE.PUBLIC_KEY,
                    'SUFeedURL': 'https://updateatlas.alperenalan.com/appcast.xml',
                    'SURequireSignedFeed': True,
                    'SUVerifyUpdateBeforeExtraction': True}
        MODULE.validate_bundle_metadata(metadata)
        with self.assertRaisesRegex(ValueError, 'production appcast'):
            MODULE.validate_bundle_metadata({**metadata, 'SUFeedURL':
                'https://alperenalan.com/apps/update-atlas/appcast.xml'})
        for old_or_other in ('dev.alperenalan.updateatlas', 'com.other.updateatlas'):
            with self.subTest(bundle_id=old_or_other), self.assertRaises(ValueError):
                MODULE.validate_bundle_metadata({**metadata, 'CFBundleIdentifier': old_or_other})

    def test_download_host_and_namespace(self):
        MODULE.validate_download_url('https://github.com/alperenalan/UpdateAtlas/releases/download/v0.1.0/App.zip', 'App.zip')
        for url in ['http://github.com/alperenalan/UpdateAtlas/releases/download/v1/App.zip',
                    'https://github.com/alperenalan/update-atlas/releases/download/v1/App.zip',
                    'https://github.com/alperenalan/updateatlas-release/releases/download/v1/App.zip',
                    'https://github.com/alperenalan/updateatlas-source/releases/download/v1/App.zip',
                    'https://alperenalan.com/downloads/App.zip',
                    'https://github.com/other-owner/UpdateAtlas/releases/download/v1/App.zip',
                    'https://github.com/alperenalan/UpdateAtlas/archive/refs/tags/App.zip',
                    'https://github.com/alperenalan/UpdateAtlas/releases/download/v..1/App.zip',
                    'https://github.com/alperenalan/UpdateAtlas/releases/download/v1/App.zip?token=x',
                    'https://github.com:8443/alperenalan/UpdateAtlas/releases/download/v1/App.zip',
                    'https://github.com.evil.test/alperenalan/UpdateAtlas/releases/download/v1/App.zip',
                    'https://user:password@github.com/alperenalan/UpdateAtlas/releases/download/v1/App.zip']:
            with self.subTest(url=url):
                with self.assertRaises(ValueError): MODULE.validate_download_url(url, 'App.zip')
    def test_nested_paths_and_internal_framework_symlink(self):
        self.check_archive('Update Atlas.app/Contents/Frameworks/Test.framework/Test', 'Versions/Current/Test', True)

    def test_parent_and_absolute_paths_are_rejected(self):
        for name in ('../outside', '/absolute', 'Update Atlas.app/../../outside', 'unrelated/file'):
            with self.subTest(name=name): self.check_archive(name, None, False)

    def test_symlinks_cannot_escape_bundle(self):
        for target in ('/Users/someone/file', '../../../../outside'):
            with self.subTest(target=target): self.check_archive('Update Atlas.app/Contents/link', target, False)

    def check_archive(self, name, target, accepted):
        scratch = ROOT / '.temporary_files/appcast-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as folder:
            archive = Path(folder) / 'test.zip'
            with zipfile.ZipFile(archive, 'w') as output:
                entry = zipfile.ZipInfo(name)
                if target is not None: entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                output.writestr(entry, target or 'test')
            if accepted: MODULE.validate_zip(archive)
            else:
                with self.assertRaises(ValueError): MODULE.validate_zip(archive)

if __name__ == '__main__': unittest.main()
