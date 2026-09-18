"""Exercise package updates and failed-session preflight without network or real CLIs."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Updates(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.modules = self.base / 'modules'
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        XDG_STATE_HOME=str(self.base / 'state'), TEST_BASE=str(self.base),
                        CC_ORCH_CLI_AUTO_UPDATE='1', CC_ORCH_STATE_DIR=str(self.base / 'sessions'))
        self.env.pop('CODEX_BIN', None)
        self.env.pop('CC_ORCH_BACKEND', None)
        for name, package in [('claude', '@anthropic-ai/claude-code'), ('codex', '@openai/codex')]:
            directory = self.modules / package
            directory.mkdir(parents=True)
            (directory / 'version').write_text('1.0.0')
            path = directory / name
            path.write_text('#!/usr/bin/env python3\nfrom pathlib import Path\nprint(Path(__file__).resolve().with_name("version").read_text())\n')
            path.chmod(0o755)
            (self.bin / name).symlink_to(path)
        self.script('npm', '''import json,os,pathlib,sys,time
b=pathlib.Path(os.environ['TEST_BASE']); a=sys.argv[1:]
with (b/'calls').open('a') as f: f.write(json.dumps(a)+'\\n')
if a[0]=='root': print(b/'modules')
elif a[0]=='view':
 if os.environ.get('FAIL_VIEW'): raise SystemExit(1)
 print(json.dumps('2.0.0'))
elif a[0]=='install':
 if os.environ.get('FAIL_INSTALL'): raise SystemExit(1)
 package,version=a[2].rsplit('@',1)
 if not os.environ.get('STALE_INSTALL'): (b/'modules'/package/'version').write_text(version)
''')
        self.script('tmux', '''import os,pathlib,sys
if sys.argv[1]=='has-session': raise SystemExit(1)
pathlib.Path(os.environ['TEST_BASE'],'tmux-created').touch()
''')

    def script(self, name, body):
        path = self.bin / name
        path.write_text('#!/usr/bin/env python3\n' + body)
        path.chmod(0o755)

    def run_update(self, *names, **env):
        return subprocess.run(['python3', str(ROOT / 'bin/orch-cli-update'), *names],
                              env=dict(self.env, **env), capture_output=True, text=True)

    def test_update_then_current_does_not_reinstall(self):
        for _ in range(2):
            result = self.run_update('claude', 'codex')
            self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (self.base / 'calls').read_text().splitlines()]
        self.assertEqual(sum(call[0] == 'install' for call in calls), 2)
        self.assertEqual(sum(call[0] == 'view' for call in calls), 4)

    def test_codex_only_does_not_update_claude(self):
        self.assertEqual(self.run_update('codex').returncode, 0)
        self.assertNotIn('anthropic', (self.base / 'calls').read_text())

    def test_offline_override_does_not_call_npm(self):
        self.assertEqual(self.run_update('codex', CC_ORCH_CLI_AUTO_UPDATE='0').returncode, 0)
        self.assertFalse((self.base / 'calls').exists())

    def test_lookup_install_and_verification_fail_closed(self):
        for key in ['FAIL_VIEW', 'FAIL_INSTALL', 'STALE_INSTALL']:
            with self.subTest(key=key):
                result = self.run_update('codex', **{key: '1'})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('launch stopped', result.stderr)

    def test_shadowed_binary_is_not_silently_updated(self):
        (self.bin / 'codex').unlink()
        self.script('codex', 'print("1.0.0")')
        self.assertNotEqual(self.run_update('codex').returncode, 0)
        self.assertNotIn('install', (self.base / 'calls').read_text())

    def test_unreadable_installed_version_is_repaired(self):
        (self.modules / '@openai/codex/version').unlink()
        result = self.run_update('codex')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.modules / '@openai/codex/version').read_text(), '2.0.0')

    def test_failed_preflight_does_not_create_session(self):
        result = subprocess.run([str(ROOT / 'bin/cc-orch-session'), 'new', 'test', str(self.base),
                                 '--inplace', '--backend', 'hybrid', '--no-attach'],
                                env=dict(self.env, FAIL_VIEW='1'), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.base / 'tmux-created').exists())
        self.assertFalse((self.base / 'sessions/sessions/test.conf').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
