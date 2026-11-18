import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/update-feed.py'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


class UpdateFeedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key_directory = tempfile.TemporaryDirectory()
        cls.key_file = Path(cls.key_directory.name) / 'test.key'
        # A fresh disposable test identity, unrelated to the production signing key.
        code = '''import Foundation; import CryptoKit
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedData().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print(key.publicKey.rawRepresentation.base64EncodedString())'''
        helper = Path(cls.key_directory.name) / 'key.swift'
        helper.write_text(code)
        cls.public_key = subprocess.check_output(['swift', str(helper), str(cls.key_file)], text=True).strip()
        cls.sign_tool = ROOT / 'build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update'

    @classmethod
    def tearDownClass(cls):
        cls.key_directory.cleanup()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.dist = Path(self.directory.name)
        self.archive = self.dist / 'DontsTool-0.2.7-macos-universal.zip'
        with zipfile.ZipFile(self.archive, 'w') as archive:
            archive.writestr('DontsTool.app/Contents/example', 'signed test archive')
        self.manifest = {
            'name': 'DontsTool', 'version': '0.2.7', 'build': '42', 'commit': '1' * 40,
            'platform': 'macOS', 'minimumSystemVersion': '26.0',
            'architectures': ['arm64', 'x86_64'], 'signing': 'developer-id',
            'teamId': 'Q2K3CAKGG2', 'notarized': True,
            'archive': self.archive.name, 'sha256': hashlib.sha256(self.archive.read_bytes()).hexdigest()
        }
        self.write_manifest()

    def write_manifest(self):
        (self.dist / 'manifest.json').write_text(json.dumps(self.manifest))

    def run_feed(self, command='generate', *, key=True, public_key=None):
        args = ['python3', str(SCRIPT), command, '--dist', str(self.dist), '--repository', 'fixture/updates',
                '--public-key', public_key or self.public_key]
        if command == 'generate':
            args += ['--sign-tool', str(self.sign_tool)]
            if key:
                args += ['--key-file', str(self.key_file)]
        environment = os.environ.copy()
        environment.pop('SPARKLE_PRIVATE_KEY', None)
        return subprocess.run(args, capture_output=True, text=True, env=environment)

    def generate(self):
        result = self.run_feed()
        self.assertEqual(result.returncode, 0, result.stderr)
        return ET.parse(self.dist / 'appcast.xml')

    def test_signed_feed_matches_the_real_archive_and_public_release_url(self):
        tree = self.generate()
        item = tree.find('./channel/item')
        self.assertEqual(item.findtext(f'{{{NS}}}version'), '42')
        self.assertEqual(item.findtext(f'{{{NS}}}shortVersionString'), '0.2.7')
        self.assertEqual(item.findtext(f'{{{NS}}}minimumSystemVersion'), '26.0.0')
        enclosure = item.find('enclosure')
        self.assertEqual(enclosure.get('url'), 'https://github.com/fixture/updates/releases/download/v0.2.7/DontsTool-0.2.7-macos-universal.zip')
        self.assertEqual(enclosure.get('length'), str(self.archive.stat().st_size))
        self.assertEqual(len(base64.b64decode(enclosure.get(f'{{{NS}}}edSignature'))), 64)
        result = self.run_feed('verify')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_private_key_is_rejected(self):
        self.assertNotEqual(self.run_feed(key=False).returncode, 0)
        self.assertFalse((self.dist / 'appcast.xml').exists())

    def test_key_not_matching_embedded_public_key_is_rejected(self):
        wrong_key = base64.b64encode(b'0' * 32).decode()
        self.assertNotEqual(self.run_feed(public_key=wrong_key).returncode, 0)
        self.assertFalse((self.dist / 'appcast.xml').exists())

    def test_archive_modified_after_signing_is_rejected_even_with_updated_sha256(self):
        self.generate()
        original = self.archive.read_bytes()
        self.archive.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
        self.manifest['sha256'] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.write_manifest()
        self.assertNotEqual(self.run_feed('verify').returncode, 0)

    def test_wrong_download_url_or_version_in_feed_is_rejected(self):
        for field in ['url', 'version', 'build', 'length']:
            with self.subTest(field=field):
                tree = self.generate()
                item = tree.find('./channel/item')
                if field == 'url':
                    item.find('enclosure').set('url', 'https://attacker.example/update.zip')
                elif field == 'length':
                    item.find('enclosure').set('length', '1')
                else:
                    element = 'shortVersionString' if field == 'version' else 'version'
                    item.find(f'{{{NS}}}{element}').text = '999'
                tree.write(self.dist / 'appcast.xml', encoding='utf-8', xml_declaration=True)
                self.assertNotEqual(self.run_feed('verify').returncode, 0)

    def test_unsafe_archive_paths_unstable_versions_and_bad_builds_are_rejected(self):
        for field, value in [('archive', '../outside.zip'), ('version', '0.2.7-beta.1'),
                             ('version', '00.2.7'), ('build', '0'), ('build', 'abc')]:
            with self.subTest(field=field, value=value):
                original = self.manifest[field]
                self.manifest[field] = value
                self.write_manifest()
                self.assertNotEqual(self.run_feed().returncode, 0)
                self.manifest[field] = original
                self.write_manifest()

    def test_unexpected_signing_or_team_metadata_is_rejected(self):
        for field, value in [('signing', 'ad-hoc'), ('notarized', False), ('teamId', 'OTHERTEAM1')]:
            with self.subTest(field=field, value=value):
                original = self.manifest[field]
                self.manifest[field] = value
                self.write_manifest()
                self.assertNotEqual(self.run_feed().returncode, 0)
                self.manifest[field] = original
                self.write_manifest()


if __name__ == '__main__':
    unittest.main()
