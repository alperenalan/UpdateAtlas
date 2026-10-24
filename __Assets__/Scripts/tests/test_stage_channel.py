"""Product-site channel staging must preserve signed bytes and reject rollback."""
import importlib.util
import json
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('stage_channel', ROOT / '__Assets__/Scripts/Apple/stage_channel.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def feed(*builds):
    items = ''.join(f'<item><sparkle:version>{build}</sparkle:version></item>' for build in builds)
    return (f'<rss xmlns:sparkle="{MODULE.SPARKLE}"><channel>{items}</channel></rss>').encode()


def catalog(revision, marker='same'):
    return json.dumps({'catalogID': 'update-atlas-bootstrap', 'revision': revision,
                       'entries': [{'id': marker}]}).encode()


class ChannelStageTests(unittest.TestCase):
    def test_continuity_rejects_dropped_items_and_revision_rollback(self):
        with self.assertRaisesRegex(ValueError, 'removed or changed'):
            MODULE.check_continuity(feed(34), feed(33), catalog(13), catalog(12), catalog(13))
        with self.assertRaisesRegex(ValueError, 'older than bundled'):
            MODULE.check_continuity(feed(34, 33), feed(33), catalog(12, 'changed'), catalog(12), catalog(13))
        with self.assertRaisesRegex(ValueError, 'without a revision increase'):
            MODULE.check_continuity(feed(33), feed(33), catalog(13, 'changed'), catalog(13), catalog(13))
        facts = MODULE.check_continuity(feed(34, 33), feed(33), catalog(13), catalog(12), catalog(13))
        self.assertEqual(facts['builds'], [34, 33])
        unchanged = MODULE.check_continuity(feed(34, 33), feed(33), catalog(12), catalog(12), catalog(13))
        self.assertEqual(unchanged['catalog_revision'], 12)
        with self.assertRaisesRegex(ValueError, 'removed bundled rule IDs'):
            MODULE.check_continuity(feed(34, 33), feed(33), catalog(14, 'new'),
                                    catalog(12, 'new'), catalog(13, 'bundled'))
        with self.assertRaisesRegex(ValueError, 'differs from bundled rules'):
            MODULE.check_continuity(feed(34, 33), feed(33),
                                    json.dumps({'catalogID': 'update-atlas-bootstrap', 'revision': 13,
                                                'entries': [{'id': 'same', 'changed': True}]}).encode(),
                                    catalog(12), catalog(13))

    def test_stages_site_channel_from_verified_bytes_and_detects_tampering(self):
        scratch = ROOT / '.temporary_files/channel-stage-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as folder:
            folder = Path(folder)
            files = {'feed': feed(34, 33), 'catalog': catalog(13),
                     'current_feed': feed(33), 'current_catalog': catalog(12),
                     'bundled': catalog(13)}
            for name, data in files.items():
                (folder / name).write_bytes(data)
            output = folder / 'staged'
            with mock.patch.object(MODULE, 'BUNDLED', folder / 'bundled'), \
                    mock.patch.object(MODULE, 'validate'), \
                    mock.patch.object(MODULE, 'validate_site_contract'):
                result = MODULE.stage(folder / 'feed', folder / 'catalog', folder / 'current_feed',
                                      folder / 'current_catalog', output)
                self.assertEqual(result['catalog']['revision'], 13)
                self.assertTrue(result['appcast']['differs_from_baseline'])
                self.assertTrue(result['catalog']['differs_from_baseline'])
                self.assertEqual(result['catalog']['added_rules'], 0)
                self.assertEqual(result['catalog']['changed_rules'], 0)
                self.assertEqual(set(result['destinations']), {'product_site', 'product_catalog'})
                self.assertTrue((output / 'product-site/Web/catalog-contract/manifest.json').is_file())
                for kind, destination, source in (('appcast', 'product_site', 'feed'),
                                                  ('catalog', 'product_catalog', 'catalog')):
                    site = output / result['destinations'][destination]
                    self.assertEqual(site.read_bytes(), files[source])
                MODULE.verify(output)
                (output / result['destinations']['product_catalog']).write_text('tampered')
                with self.assertRaisesRegex(ValueError, 'differs from manifest'):
                    MODULE.verify(output)

    def test_refuses_output_outside_scratch(self):
        with self.assertRaisesRegex(ValueError, 'project .temporary_files'):
            MODULE.stage(Path('unused'), Path('unused'), Path('unused'), Path('unused'), ROOT / 'staged')

    def test_refuses_existing_output_without_replacing_it(self):
        scratch = ROOT / '.temporary_files/channel-stage-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as folder:
            output = Path(folder) / 'staged'
            output.mkdir()
            marker = output / 'keep'
            marker.write_text('original')
            with self.assertRaisesRegex(ValueError, 'new output directory'):
                MODULE.stage(Path('unused'), Path('unused'), Path('unused'), Path('unused'), output)
            self.assertEqual(marker.read_text(), 'original')

    def test_product_site_build_gate_checks_manifest_and_full_snapshot(self):
        scratch = ROOT / '.temporary_files/channel-stage-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as folder:
            web = Path(folder) / 'Web'
            contract = web / 'catalog-contract'
            for destination, source in MODULE.SITE_CONTRACT.items():
                target = contract / destination
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
            public = web / 'site/api/update-atlas/catalog-v1.json'
            public.parent.mkdir(parents=True)
            data = MODULE.BUNDLED.read_bytes()
            public.write_bytes(data)
            def write_manifest(payload):
                (contract / 'manifest.json').write_text(json.dumps({'catalog': {
                    'sha256': hashlib.sha256(payload).hexdigest(), 'bytes': len(payload),
                    'revision': json.loads(payload)['revision'], 'rules': len(json.loads(payload)['entries'])},
                    'catalog_contract': {str(destination): {
                        'sha256': hashlib.sha256((contract / destination).read_bytes()).hexdigest(),
                        'bytes': (contract / destination).stat().st_size}
                        for destination in MODULE.SITE_CONTRACT}}))
            write_manifest(data)
            script = contract / 'Scripts/validate_site_catalog.mjs'
            self.assertEqual(subprocess.run(['node', str(script)], capture_output=True).returncode, 0)
            edited = json.loads(data)
            edited['entries'].pop()
            changed = json.dumps(edited).encode()
            public.write_bytes(changed)
            self.assertNotEqual(subprocess.run(['node', str(script)], capture_output=True).returncode, 0)
            write_manifest(changed)
            self.assertNotEqual(subprocess.run(['node', str(script)], capture_output=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
