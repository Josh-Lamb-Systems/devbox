"""Tests embedded cloud-init assets without provisioning a machine.
Requires PyYAML, or Ruby's YAML parser as a fallback.
"""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
try:
    import yaml
    CONFIG = yaml.safe_load((ROOT / 'jls-ubuntu-dev-vendor-data.yaml').read_text())
except ImportError:
    CONFIG = json.loads(subprocess.check_output([
        'ruby', '-r', 'yaml', '-r', 'json', '-e',
        'puts JSON.generate(YAML.load_file(ARGV[0]))',
        str(ROOT / 'jls-ubuntu-dev-vendor-data.yaml')], text=True))
ASSETS = {item['path']: item['content'] for item in CONFIG['write_files']}


def load_module(path, name):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class AwarenessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path, content in ASSETS.items():
            dest = self.root / Path(path).name
            dest.write_text(content)
            dest.chmod(0o755)
        self.installer = load_module(self.root / 'install-agent-context', 'installer')
        self.doctor = load_module(self.root / 'jls-doctor', 'doctor')

    def test_embedded_scripts_compile(self):
        for path, content in ASSETS.items():
            if content.startswith('#!/usr/bin/python3'):
                compile(content, path, 'exec')
            elif content.startswith('#!/usr/bin/env bash') or content.startswith('#!/bin/sh'):
                subprocess.run(['bash', '-n'], input=content, text=True, check=True)

    def test_instruction_updates_preserve_user_text_and_are_idempotent(self):
        home = self.root / 'home'
        home.mkdir()
        source = self.root / 'agent-context.md'
        codex = home / '.codex'
        codex.mkdir()
        original = 'Personal rules\n'
        (codex / 'AGENTS.md').write_text(original)
        (codex / 'AGENTS.override.md').write_text('Temporary rules\n')
        with patch.dict(os.environ, {'CODEX_HOME': str(codex)}):
            self.installer.install(home, source)
            first = (codex / 'AGENTS.md').read_text()
            self.installer.install(home, source)
            self.assertEqual(first, (codex / 'AGENTS.md').read_text())
            source.write_text('Updated guidance\n')
            self.installer.install(home, source)
        for file in [codex / 'AGENTS.md', codex / 'AGENTS.override.md', home / '.claude/CLAUDE.md']:
            text = file.read_text()
            self.assertIn('Updated guidance', text)
            self.assertEqual(text.count(self.installer.START), 1)
        self.assertTrue((codex / 'AGENTS.md').read_text().startswith(original))
        self.assertTrue((codex / 'AGENTS.override.md').read_text().startswith('Temporary rules\n'))

    def test_malformed_markers_fail_without_writes(self):
        home = self.root / 'home'
        codex = home / '.codex'
        codex.mkdir(parents=True)
        file = codex / 'AGENTS.md'
        file.write_text(self.installer.START + '\npersonal text')
        with patch.dict(os.environ, {'CODEX_HOME': str(codex)}):
            with self.assertRaises(ValueError):
                self.installer.install(home, self.root / 'agent-context.md')
        self.assertEqual(file.read_text(), self.installer.START + '\npersonal text')
        self.assertFalse((home / '.claude').exists())

    def test_symlink_preserved(self):
        home = self.root / 'home'
        codex = home / '.codex'
        codex.mkdir(parents=True)
        target = self.root / 'personal.md'
        target.write_text('Personal rules\n')
        link = codex / 'AGENTS.md'
        link.symlink_to(target)
        with patch.dict(os.environ, {'CODEX_HOME': str(codex)}):
            self.installer.install(home, self.root / 'agent-context.md')
        self.assertTrue(link.is_symlink())
        self.assertIn('Personal rules', target.read_text())

    def test_launcher_without_shell_startup_preserves_arguments(self):
        home = self.root / 'home with spaces'
        bindir = home / '.local/bin'
        bindir.mkdir(parents=True)
        fake = bindir / 'example-agent'
        fake.write_text('#!/bin/sh\nprintf "%s\\n" "$HOME" "$PATH" "$@"\n')
        fake.chmod(0o755)
        result = subprocess.run(['/bin/bash', str(self.root / 'jls-run'), 'example-agent', 'a b', '--flag'],
                                env={'HOME': str(home), 'PATH': '/usr/bin:/bin'},
                                text=True, capture_output=True, check=True)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], str(home))
        self.assertTrue(lines[1].startswith(str(bindir) + ':' + str(home / '.local/share/mise/shims')))
        self.assertEqual(lines[-2:], ['a b', '--flag'])

    def test_doctor_distinguishes_docker_access_and_optional_kvm(self):
        def probe(argv):
            ok = argv[:2] != ['docker', 'info']
            return {'ok': ok, 'exit_code': 0 if ok else 1, 'output': 'version' if ok else ''}
        with patch.object(self.doctor.shutil, 'which', side_effect=lambda name: '/bin/' + name), \
             patch.object(self.doctor, 'probe', side_effect=probe), \
             patch.object(self.doctor.Path, 'is_file', return_value=True), \
             patch.object(self.doctor.os, 'access', return_value=False):
            report = self.doctor.collect()
        self.assertTrue(report['commands']['docker']['available'])
        self.assertTrue(report['docker']['compose']['ok'])
        self.assertFalse(report['docker']['daemon_access']['ok'])
        self.assertFalse(report['kvm']['accessible'])
        self.assertEqual(report['failures'], ['docker:daemon_access'])
        self.assertIn('uv', report['commands'])

    def test_doctor_failed_probe_timeout_and_json_exit(self):
        with patch.object(self.doctor.subprocess, 'run', side_effect=subprocess.TimeoutExpired('probe', 5)):
            self.assertFalse(self.doctor.probe(['probe'])['ok'])
        # No fake PATH repair: this reports exactly what the caller can access.
        result = subprocess.run([os.sys.executable, str(self.root / 'jls-doctor'), '--json'],
                                env={**os.environ, 'PATH': str(self.root / 'empty')},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertFalse(report['ready'])
        self.assertFalse(report['commands']['uv']['available'])
        self.assertIn('bootstrap:incomplete', report['failures'])


if __name__ == '__main__':
    unittest.main()
