import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='dontstool-installer-test-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.release = self.root / 'release'
        self.release.mkdir()
        self.target = self.root / 'Applications with spaces'
        self.target.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.archive_name = 'DontsTool-0.2.6-macos-universal.zip'
        self.app = self.root / 'source' / 'DontsTool.app'
        (self.app / 'Contents' / 'MacOS').mkdir(parents=True)
        self.info = {
            'CFBundleIdentifier': 'com.donts.DontsTool',
            'CFBundleExecutable': 'DontsTool',
            'CFBundleName': 'DontsTool',
            'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': '0.2.6',
            'CFBundleVersion': '1',
        }
        shutil.copy('/usr/bin/true', self.app / 'Contents/MacOS/DontsTool')
        self.sign_and_package()
        self.mock('curl', '''#!/usr/bin/env python3
import os, pathlib, shutil, sys
args = sys.argv[1:]
url = args[-1]
prefix = 'https://github.com/CrxusDonts/DontsTool/releases/'
if not url.startswith(prefix):
    raise SystemExit(2)
relative = url[len(prefix):]
ver = os.environ.get('DT_TEST_VERSION', '0.2.6')
if relative not in ('latest/download/manifest.json', f'download/v{ver}/manifest.json',
                    f'download/v{ver}/SHA256SUMS', f'download/v{ver}/DontsTool-{ver}-macos-universal.zip'):
    raise SystemExit(3)
with open(os.environ['DT_TEST_REQUESTS'], 'a') as log:
    log.write(relative + '\\n')
shutil.copy(pathlib.Path(os.environ['DT_TEST_RELEASE']) / relative.split('/')[-1], args[args.index('--output') + 1])
''')
        self.mock('pgrep', '#!/bin/bash\nexit "${DT_TEST_RUNNING:-1}"\n')
        self.mock('sw_vers', '#!/bin/bash\nprintf "%s\\n" "${DT_TEST_OS:-26.0}"\n')
        self.environment = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                                DT_TEST_RELEASE=str(self.release),
                                DT_TEST_REQUESTS=str(self.root / 'requests'),
                                DT_TEST_VERSION='0.2.6')

    def mock(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def sign_and_package(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(self.app)],
                       check=True, capture_output=True)
        self.package()

    def package(self):
        archive = self.release / self.archive_name
        archive.unlink(missing_ok=True)
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(self.app), str(archive)], check=True)
        self.checksums()

    def checksums(self, manifest_extra=None):
        digest = hashlib.sha256((self.release / self.archive_name).read_bytes()).hexdigest()
        manifest = {'name': 'DontsTool', 'version': self.info['CFBundleShortVersionString'], 'platform': 'macOS',
                    'minimumSystemVersion': '26.0', 'archive': self.archive_name, 'sha256': digest}
        if manifest_extra:
            manifest.update(manifest_extra)
        (self.release / 'manifest.json').write_text(json.dumps(manifest))
        (self.release / 'SHA256SUMS').write_text(''.join(
            f'{hashlib.sha256((self.release / name).read_bytes()).hexdigest()}  {name}\n'
            for name in (self.archive_name, 'manifest.json')))

    def prepare_release(self, version, manifest_extra=None):
        for old_file in self.release.iterdir():
            old_file.unlink()
        self.info['CFBundleShortVersionString'] = version
        self.archive_name = f'DontsTool-{version}-macos-universal.zip'
        self.environment['DT_TEST_VERSION'] = version
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(self.app)],
                       check=True, capture_output=True)
        archive = self.release / self.archive_name
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(self.app), str(archive)], check=True)
        self.checksums(manifest_extra=manifest_extra)

    def run_install(self, *args, **environment):
        return subprocess.run(['bash', str(ROOT / 'install.sh'), '--dir', str(self.target), *args],
                              env=dict(self.environment, **environment), capture_output=True, text=True)

    def old_app(self):
        old = self.target / 'DontsTool.app'
        shutil.copytree(self.app, old)
        (old / 'old-marker').write_text('old application')
        return old

    def assert_rejected(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)

    def test_installs_real_signed_bundle_and_pins_downloads(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        installed = self.target / 'DontsTool.app'
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(installed)], check=True, capture_output=True)
        self.assertEqual((self.root / 'requests').read_text().splitlines(), [
            'latest/download/manifest.json', 'download/v0.2.6/SHA256SUMS',
            'download/v0.2.6/DontsTool-0.2.6-macos-universal.zip'])
        self.assertFalse(list(self.target.glob('.DontsTool-install.*')))

    def test_replaces_old_app_with_explicit_release(self):
        self.old_app()
        result = self.run_install('--version', 'v0.2.6')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.target / 'DontsTool.app/old-marker').exists())
        self.assertTrue((self.root / 'requests').read_text().startswith('download/v0.2.6/manifest.json\n'))

    def test_running_application_is_untouched_and_not_downloaded(self):
        old = self.old_app()
        self.assert_rejected(self.run_install(DT_TEST_RUNNING='0'), '正在运行')
        self.assertTrue((old / 'old-marker').exists())
        self.assertFalse((self.root / 'requests').exists())

    def test_corrupt_download_preserves_old_application(self):
        old = self.old_app()
        with (self.release / self.archive_name).open('ab') as archive:
            archive.write(b'corruption')
        self.assert_rejected(self.run_install(), 'SHA256 校验失败')
        self.assertTrue((old / 'old-marker').exists())

    def test_checksum_cannot_omit_manifest(self):
        sums = self.release / 'SHA256SUMS'
        sums.write_text(sums.read_text().splitlines()[0] + '\n')
        self.assert_rejected(self.run_install(), '缺少或重复记录')
        self.assertFalse((self.target / 'DontsTool.app').exists())

    def test_unrelated_existing_directory_is_not_overwritten(self):
        existing = self.target / 'DontsTool.app'
        existing.mkdir()
        self.assert_rejected(self.run_install(), '拒绝覆盖')
        self.assertTrue(existing.is_dir())

    def test_invalid_signature_is_rejected_even_with_valid_checksums(self):
        executable = self.app / 'Contents/MacOS/DontsTool'
        with executable.open('ab') as binary:
            binary.write(b'tampered')
        self.package()
        self.assert_rejected(self.run_install(), '签名完整性检查失败')
        self.assertFalse((self.target / 'DontsTool.app').exists())

    def test_signed_wrong_bundle_identifier_is_rejected(self):
        self.info['CFBundleIdentifier'] = 'example.someone-else'
        self.sign_and_package()
        self.assert_rejected(self.run_install(), '应用标识不匹配')

    def test_archive_traversal_is_rejected_before_extraction(self):
        with zipfile.ZipFile(self.release / self.archive_name, 'a') as archive:
            archive.writestr('DontsTool.app/../../outside', 'bad path')
        self.checksums()
        self.assert_rejected(self.run_install(), '不安全路径')
        self.assertFalse((self.target / 'DontsTool.app').exists())

    def test_failed_replacement_restores_old_application(self):
        old = self.old_app()
        self.mock('mv', '''#!/bin/bash
if [[ "$1" == */.DontsTool-install.*/DontsTool.app ]]; then exit 1; fi
exec /bin/mv "$@"
''')
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((old / 'old-marker').exists(), result.stderr)
        self.assertFalse(list(self.target.glob('.DontsTool-install.*')))

    def test_interrupted_replacement_restores_old_application(self):
        old = self.old_app()
        self.mock('mv', '''#!/bin/bash
if [[ "$1" == */.DontsTool-install.*/DontsTool.app ]]; then
  kill -TERM "$PPID"
  exit 1
fi
exec /bin/mv "$@"
''')
        result = self.run_install()
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        self.assertTrue((old / 'old-marker').exists(), result.stderr)
        self.assertFalse(list(self.target.glob('.DontsTool-install.*')))

    def test_application_started_during_download_prevents_replacement(self):
        old = self.old_app()
        self.mock('pgrep', '''#!/bin/bash
if [[ -e "$DT_TEST_REQUESTS" ]]; then exit 0; fi
exit 1
''')
        self.assert_rejected(self.run_install(), '正在运行')
        self.assertTrue((old / 'old-marker').exists())
        self.assertTrue((self.root / 'requests').exists())
        self.assertFalse(list(self.target.glob('.DontsTool-install.*')))

    def test_unsupported_system_does_not_download(self):
        self.assert_rejected(self.run_install(DT_TEST_OS='15.7'), '需要 macOS 26')
        self.assertFalse((self.root / 'requests').exists())

    def test_overlapping_installers_cannot_corrupt_application(self):
        self.old_app()
        paused = self.root / 'paused'
        resume = self.root / 'resume'
        self.mock('mv', '''#!/bin/bash
if [[ "${DT_TEST_PAUSE:-0}" == 1 && "$1" == */.DontsTool-install.*/DontsTool.app ]]; then
  touch "$DT_TEST_PAUSED"
  while [[ ! -e "$DT_TEST_RESUME" ]]; do sleep 0.05; done
fi
exec /bin/mv "$@"
''')
        first = subprocess.Popen(['bash', str(ROOT / 'install.sh'), '--dir', str(self.target)],
                                 env=dict(self.environment, DT_TEST_PAUSE='1',
                                          DT_TEST_PAUSED=str(paused), DT_TEST_RESUME=str(resume)),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while not paused.exists() and first.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(paused.exists(), 'First installer did not reach replacement')
            self.assert_rejected(self.run_install(), '安装锁')
        finally:
            resume.touch()
            stdout, stderr = first.communicate(timeout=10)
        self.assertEqual(first.returncode, 0, stdout + stderr)
        installed = self.target / 'DontsTool.app'
        self.assertFalse((installed / 'DontsTool.app').exists())
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(installed)], check=True, capture_output=True)

    def test_notarized_release_rejects_signing_downgrade_in_manifest(self):
        cases = [
            {'signing': 'ad-hoc', 'teamId': 'Q2K3CAKGG2', 'notarized': True},
            {'signing': 'developer-id', 'teamId': 'OTHERTEAM1', 'notarized': True},
            {'signing': 'developer-id', 'teamId': 'Q2K3CAKGG2', 'notarized': False},
            {},
        ]
        for extra in cases:
            with self.subTest(extra=extra):
                self.prepare_release('0.2.10', manifest_extra=extra)
                self.assert_rejected(self.run_install('--version', 'v0.2.10'), '发布签名元数据无效')
                self.assertFalse((self.target / 'DontsTool.app').exists())

    def test_notarized_release_rejects_adhoc_signed_bundle(self):
        self.prepare_release('0.2.10', manifest_extra={
            'signing': 'developer-id', 'teamId': 'Q2K3CAKGG2', 'notarized': True
        })
        self.assert_rejected(self.run_install('--version', 'v0.2.10'), '应用签名完整性检查失败')
        self.assertFalse((self.target / 'DontsTool.app').exists())

    def test_notarized_release_verifies_developer_id_and_stapler(self):
        self.prepare_release('0.2.10', manifest_extra={
            'signing': 'developer-id', 'teamId': 'Q2K3CAKGG2', 'notarized': True
        })
        codesign_log = self.root / 'codesign.log'
        xcrun_log = self.root / 'xcrun.log'
        self.mock('codesign', '''#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
req_args = [a for a in args if a.startswith('-R=')]
if req_args:
    assert 'Q2K3CAKGG2' in req_args[0], f'Missing team ID in requirement: {req_args[0]}'
    with open(os.environ['DT_TEST_CODESIGN_LOG'], 'a') as f:
        f.write(req_args[0] + '\\n')
    filtered = [a for a in args if not a.startswith('-R=')]
    sys.exit(subprocess.call(['/usr/bin/codesign', *filtered]))
sys.exit(subprocess.call(['/usr/bin/codesign', *args]))
''')
        self.mock('xcrun', '''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
assert len(args) == 3 and args[0] == 'stapler' and args[1] == 'validate', f'Unexpected xcrun args: {args}'
with open(os.environ['DT_TEST_XCRUN_LOG'], 'a') as f:
    f.write(args[2] + '\\n')
''')
        result = self.run_install('--version', 'v0.2.10',
                                  DT_TEST_CODESIGN_LOG=str(codesign_log),
                                  DT_TEST_XCRUN_LOG=str(xcrun_log))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(codesign_log.read_text().splitlines()), 3)
        self.assertEqual(len(xcrun_log.read_text().splitlines()), 3)
        self.assertNotIn('未经 Apple 公证', result.stdout)
        self.assertTrue((self.target / 'DontsTool.app').is_dir())


if __name__ == '__main__':
    unittest.main()
