"""Offline workflow checks with mocked Proxmox/libguestfs/network commands.
Run: python3 -m unittest discover -s tests -v
Only Linux-specific bridge/lock paths are redirected in a temporary script copy.
No image download, virtualization, root access, or host configuration is needed.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IMAGE = b'fixture cloud image'
MOCK = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ['MOCK_ROOT'])
mode = os.environ.get('MOCK_MODE', '')
with (root / 'calls').open('a') as f:
    f.write(json.dumps([name] + args) + '\n')
if name == 'id': print('0')
elif name == 'uname': print('x86_64')
elif name == 'flock': pass
elif name == 'pvesh':
    if mode == 'api_failure': sys.exit(1)
    print(json.dumps([{'vmid': 9000, 'type': 'lxc'}] if mode == 'duplicate' else []))
elif name == 'pvesm':
    if args[0] == 'path': print(root / 'snippets' / args[1].split('/')[-1])
    else:
        storage = args[args.index('--storage') + 1]
        print('Name Type Status Total Used Available %')
        print(storage, 'dir', 'inactive' if mode == 'storage' else 'active', '100 1 99 1')
elif name == 'curl':
    target = pathlib.Path(args[args.index('--output') + 1])
    if target.name == 'releases.json': target.write_bytes((root / 'metadata').read_bytes())
    else: target.write_bytes(b'bad' if mode == 'checksum' else b'fixture cloud image')
elif name == 'sha256sum':
    expected, path = sys.stdin.read().strip().split(None, 1)
    sys.exit(0 if hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() == expected else 1)
elif name == 'qemu-img': print(json.dumps({'format': 'qcow2', 'virtual-size': 4 * 1024**3}))
elif name == 'virt-customize':
    if mode == 'customize': sys.exit(1)
elif name == 'qm':
    if mode == 'import' and '--scsi0' in args: sys.exit(1)
'''


class TemplateMakerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        bindir = self.root / 'bin'
        bindir.mkdir()
        for name in ['id', 'uname', 'flock', 'qm', 'pvesm', 'pvesh', 'curl',
                     'qemu-img', 'virt-customize', 'sha256sum']:
            path = bindir / name
            path.write_text(MOCK)
            path.chmod(0o755)
        bridge = self.root / 'bridge'
        bridge.mkdir()
        source = (ROOT / 'qmtemplatemaker.sh').read_text()
        source = source.replace('/sys/class/net/$BRIDGE/bridge', str(bridge))
        source = source.replace('/run/lock/jls-template-maker.lock', str(self.root / 'lock'))
        self.script = self.root / 'maker.sh'
        self.script.write_text(source)
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.root / 'key')], check=True)
        digest = hashlib.sha256(IMAGE).hexdigest()
        products = {}
        for version, title, supported in [('24.04', '24.04 LTS', True), ('26.04', '26.04 LTS', True),
                                          ('26.10', '26.10', True), ('28.04', '28.04 LTS', False)]:
            products[version] = dict(arch='amd64', os='ubuntu', version=version,
                                    release='test', release_title=title, supported=supported,
                                    versions={'20261001': {'label': 'release', 'items': {
                                        'disk1.img': {'path': f'server/releases/{version}/release-20261001/ubuntu.img',
                                                      'sha256': digest}}}})
        (self.root / 'metadata').write_text(json.dumps({'products': products}))
        self.env = {**os.environ, 'PATH': f'{bindir}:{os.environ["PATH"]}',
                    'MOCK_ROOT': str(self.root), 'WORK_ROOT': str(self.root),
                    'SSH_KEY': str(self.root / 'key.pub'),
                    'VENDOR_DATA': str(ROOT / 'jls-ubuntu-dev-vendor-data.yaml')}

    def run_build(self, mode='', **overrides):
        result = subprocess.run(['bash', str(self.script)], env={**self.env, 'MOCK_MODE': mode, **overrides},
                                text=True, capture_output=True)
        calls = [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]
        self.assertFalse(list(self.root.glob('jls-template.*')), 'staging files leaked')
        self.assertFalse(any(c[:2] in [['qm', 'start'], ['qm', 'destroy']] for c in calls))
        return result, calls

    def test_success_selects_latest_lts_and_attaches_vendor(self):
        result, calls = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Ubuntu 26.04 LTS', result.stdout)
        self.assertEqual(calls[-1], ['qm', 'template', '9000'])
        self.assertTrue(any('vendor=local:snippets/jls-ubuntu-dev-vendor-data.yaml' in c for c in calls))
        self.assertTrue(any('--truncate' in c and '/etc/machine-id' in c for c in calls))
        self.assertEqual((self.root / 'snippets/jls-ubuntu-dev-vendor-data.yaml').read_bytes(),
                         (ROOT / 'jls-ubuntu-dev-vendor-data.yaml').read_bytes())

    def test_pin_and_custom_snippet(self):
        result, calls = self.run_build(UBUNTU_RELEASE='24.04', SNIPPET_NAME='custom.yaml')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Ubuntu 24.04 LTS', result.stdout)
        self.assertTrue(any('vendor=local:snippets/custom.yaml' in c for c in calls))

    def test_precreation_failures(self):
        for mode in ['duplicate', 'api_failure', 'storage', 'checksum', 'customize']:
            with self.subTest(mode=mode):
                (self.root / 'calls').write_text('')
                result, calls = self.run_build(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(c[:2] == ['qm', 'create'] for c in calls))

    def test_import_failure_retains_vm(self):
        result, calls = self.run_build('import')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('retained for inspection', result.stderr)
        self.assertFalse(any(c[:2] == ['qm', 'template'] for c in calls))

    def test_different_existing_snippet_is_not_overwritten(self):
        snippets = self.root / 'snippets'
        snippets.mkdir()
        snippet = snippets / 'jls-ubuntu-dev-vendor-data.yaml'
        snippet.write_text('existing content')
        result, calls = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snippet.read_text(), 'existing content')
        self.assertFalse(any(c[0] == 'curl' for c in calls))

    def test_unknown_release(self):
        result, calls = self.run_build(UBUNTU_RELEASE='99.04')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[:2] == ['qm', 'create'] for c in calls))

    def test_too_small_disk(self):
        result, calls = self.run_build(DISK_GB='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == 'virt-customize' for c in calls))


if __name__ == '__main__':
    unittest.main()
