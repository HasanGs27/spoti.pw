"""Offline supervisor tests; startup shortcuts are created only in temporary folders."""
import contextlib
from dataclasses import replace
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

import pc_companion_launcher as launcher


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='spoti-launcher-test-')
        self.root = Path(self.temporary.name)
        self.config = launcher.Config.workspace(self.root, self.root / 'pairing')
        self.config.folder.mkdir()
        self.token = 'a' * 32
        self.value = {'url': 'http://192.168.1.8:8768/' + self.token + '/', 'futureField': {'keep': True}}
        self.config.session.write_text(json.dumps(self.value, indent=2), encoding='utf-8')
        self.output = io.StringIO()
        self.redirect = contextlib.redirect_stdout(self.output)
        self.redirect.__enter__()

    def tearDown(self):
        self.redirect.__exit__(None, None, None)
        self.temporary.cleanup()

    def snapshot(self):
        return {str(p.relative_to(self.root)): (p.read_bytes(), p.stat().st_mtime_ns)
                for p in self.root.rglob('*') if p.is_file()}

    def supervisor(self, **kwargs):
        self.now, self.address = 0, '192.168.1.8'
        self.children = []
        def spawn(config, address):
            child = Mock()
            child.poll.return_value = None
            self.children.append((config, address, child))
            return child
        def detector():
            if self.address is None: raise OSError('offline')
            return self.address
        return launcher.Supervisor(self.config, clock=lambda: self.now,
            detector=detector, health=kwargs.pop('health', lambda *args: False),
            spawn=kwargs.pop('spawn', spawn), **kwargs)

    def test_session_no_change_is_byte_preserved_and_ip_change_keeps_token_fields(self):
        before = self.snapshot()
        self.assertEqual(launcher.update_address(self.config, '192.168.1.8'), (8768, self.token))
        self.assertEqual(before, self.snapshot())
        self.assertEqual(launcher.update_address(self.config, '192.168.1.9'), (8768, self.token))
        saved = json.loads(self.config.session.read_text(encoding='utf-8'))
        self.assertEqual(saved, self.value | {'url': 'http://192.168.1.9:8768/' + self.token + '/'})
        self.assertEqual(list(self.config.folder.iterdir()), [self.config.session])

    def test_missing_or_invalid_pairing_is_never_recreated(self):
        self.config.session.unlink()
        with self.assertRaises(OSError): launcher.update_address(self.config, '192.168.1.8')
        self.assertEqual(list(self.config.folder.iterdir()), [])
        for url in ('https://192.168.1.8:8768/' + self.token + '/',
                    'http://8.8.8.8:8768/' + self.token + '/',
                    'http://user@192.168.1.8:8768/' + self.token + '/',
                    'http://192.168.1.8:8768/prefix/' + self.token + '/',
                    'http://192.168.1.8:8768/short/'):
            self.config.session.write_text(json.dumps({'url': url}), encoding='utf-8')
            before = self.snapshot()
            with self.assertRaises(ValueError): launcher.update_address(self.config, '192.168.1.8')
            self.assertEqual(before, self.snapshot())

    def test_delayed_network_single_child_and_ip_change_only_closes_owned_child(self):
        supervisor = self.supervisor()
        self.address = None
        for _ in range(3): supervisor.step()
        self.assertEqual(self.children, [])
        self.address = '192.168.1.8'
        supervisor.step(); supervisor.step()
        self.assertEqual(len(self.children), 1)
        first = self.children[0][2]
        self.address = '192.168.1.9'
        supervisor.step()
        first.close.assert_called_once()
        self.assertEqual(len(self.children), 2)
        self.assertEqual(self.children[-1][1], self.address)
        self.address = None
        supervisor.step(); supervisor.step()
        self.children[-1][2].close.assert_called_once()
        self.assertEqual(json.loads(self.config.session.read_text()), self.value)

    def test_existing_backend_is_adopted_without_kill_or_duplicate(self):
        healthy = Mock(return_value=True)
        supervisor = self.supervisor(health=healthy)
        for _ in range(3): supervisor.step()
        supervisor.close()
        self.assertEqual(self.children, [])
        healthy.return_value = False
        supervisor.step()
        self.assertEqual(len(self.children), 1)

    def test_crash_restart_backoff_is_bounded_and_resets_after_stable_minute(self):
        supervisor = self.supervisor()
        supervisor.step()
        for attempt in range(1, 9):
            self.children[-1][2].poll.return_value = 1
            supervisor.step()
            self.assertEqual(supervisor.next_start - self.now, min(60, 2 ** min(attempt, 6)))
            count = len(self.children)
            self.now = supervisor.next_start - .01
            supervisor.step()
            self.assertEqual(count, len(self.children))
            self.now += .01
            supervisor.step()
            self.assertEqual(count + 1, len(self.children))
        self.now += 60
        supervisor.step()
        self.assertEqual(supervisor.failures, 0)
        self.children[-1][2].poll.return_value = 1
        supervisor.step()
        self.assertEqual(supervisor.next_start - self.now, 2)

    def test_failed_spawn_is_throttled(self):
        spawn = Mock(side_effect=OSError('denied'))
        supervisor = self.supervisor(spawn=spawn)
        for _ in range(10): supervisor.step()
        self.assertEqual(spawn.call_count, 1)
        self.now = 2
        supervisor.step()
        self.assertEqual(spawn.call_count, 2)
        self.assertEqual(supervisor.next_start, 6)

    def test_old_address_is_never_probed_and_check_is_sanitized_read_only(self):
        (self.config.folder / 'server-output.log').write_text('existing log', encoding='utf-8')
        before = self.snapshot()
        with patch.object(launcher, 'installation', return_value=([], {'zeroconf': '0.151.3'})), \
             patch.object(launcher, 'detect_lan', return_value='192.168.1.9'), \
             patch.object(launcher, 'resident_running', return_value=False), \
             patch.object(launcher, 'startup', return_value={'enabled': False, 'owned': False}) as startup, \
             patch.object(launcher, 'ready') as ready, \
             patch.object(launcher.subprocess, 'Popen') as popen:
            status = launcher.inspect(self.config)
            self.assertTrue(status['addressChanged'])
            self.assertFalse(status['ready'])
            ready.assert_not_called(); popen.assert_not_called()
            startup.assert_called_once_with(self.config)
            self.assertNotIn(self.token, json.dumps(status))
        self.assertEqual(before, self.snapshot())

    def test_manual_shortcut_joins_existing_resident(self):
        with patch.object(launcher, 'inspect', return_value={'resident': True, 'issues': [], 'ready': True}), \
             patch.object(launcher, 'detect_lan', return_value='192.168.1.8'), \
             patch.object(launcher, 'ready', return_value=True), \
             patch.object(launcher.subprocess, 'Popen') as popen:
            self.assertEqual(launcher.main([], self.config), 0)
            popen.assert_not_called()
        self.assertNotIn(self.token, self.output.getvalue())

    def test_check_flag_never_enables_startup_or_starts_service(self):
        status = {'resident': False, 'issues': [], 'ready': False}
        with patch.object(launcher, 'inspect', return_value=status), \
             patch.object(launcher, 'startup') as startup, patch.object(launcher, 'resident') as resident:
            self.assertEqual(launcher.main(['--check', '--json', '--startup-enable'], self.config), 0)
            startup.assert_not_called(); resident.assert_not_called()

    def test_manual_offline_starts_hidden_resident_and_waits_without_claiming_ready(self):
        with patch.object(launcher, 'inspect', return_value={'resident': False, 'issues': [launcher.NETWORK_ISSUE], 'ready': False}), \
             patch.object(launcher, 'detect_lan', side_effect=OSError('offline')), \
             patch.object(launcher, 'resident_running', return_value=True), \
             patch.object(launcher.time, 'sleep'), patch.object(launcher.subprocess, 'Popen') as popen:
            self.assertEqual(launcher.main([], self.config), 0)
            popen.assert_called_once()
            self.assertIn('--resident', popen.call_args.args[0])
            self.assertNotIn('--serve', popen.call_args.args[0])
            self.assertEqual(popen.call_args.kwargs['stdin'], subprocess.DEVNULL)
        self.assertNotIn('PC prêt.', self.output.getvalue())
        self.assertNotIn(self.token, self.output.getvalue())

    @unittest.skipUnless(os.name == 'nt', 'Windows backend file lock')
    def test_serve_reuses_pairing_and_requests_unlimited_backend_lifetime(self):
        captured = []
        def backend(*args, **kwargs):
            captured.extend(sys.argv)
            print(json.loads(self.config.session.read_text())['url'])
        with patch.object(launcher, 'node_runtime', return_value=(Path('node.exe'), 'v22.0.0')), \
             patch.object(launcher.runpy, 'run_path', side_effect=backend), \
             patch.dict(os.environ), patch.object(launcher.sys, 'argv', []), \
             patch.object(launcher.sys, 'path', list(sys.path)):
            self.assertEqual(launcher.serve(self.config, '192.168.1.9'), 0)
            self.assertEqual(os.environ['SG_ARTWORK_CACHE_DIR'], str(self.config.folder / 'jobs/.artwork-cache'))
        self.assertEqual(captured[-2:], ['--lifetime-seconds', '0'])
        saved = json.loads(self.config.session.read_text())
        self.assertEqual(saved['futureField'], self.value['futureField'])
        self.assertIn(self.token, saved['url'])
        self.assertNotIn(self.token, (self.config.folder / 'server-output.log').read_text(encoding='utf-8'))

    def test_duplicate_resident_returns_without_opening_logs_or_spawn(self):
        @contextlib.contextmanager
        def held(config): yield False
        before = self.snapshot()
        with patch.object(launcher, 'resident_lock', held), patch.object(launcher, 'installation') as check:
            self.assertEqual(launcher.resident(self.config), 0)
            check.assert_not_called()
        self.assertEqual(before, self.snapshot())

    def test_zeroconf_exact_pin_checked(self):
        with patch.object(launcher.importlib.metadata, 'version', side_effect=lambda name: '0.151.2' if name == 'zeroconf' else '1.0'), \
             patch.object(launcher, 'node_runtime', return_value=(Path('node.exe'), 'v22.0.0')):
            issues, _ = launcher.installation(self.config)
            self.assertIn('Dépendance requise : zeroconf==0.151.3', issues)

    @unittest.skipUnless(os.name == 'nt', 'Windows mutex and COM shortcut')
    def test_real_mutex_prevents_other_thread_and_disappears_after_release(self):
        results = []
        before = self.snapshot()
        self.assertFalse(launcher.resident_running(self.config))
        with launcher.resident_lock(self.config) as acquired:
            self.assertTrue(acquired)
            def other():
                results.append(launcher.resident_running(self.config))
                with launcher.resident_lock(self.config) as second: results.append(second)
            thread = threading.Thread(target=other)
            thread.start(); thread.join(timeout=5)
            self.assertFalse(thread.is_alive())
        self.assertEqual(results, [True, False])
        self.assertFalse(launcher.resident_running(self.config))
        self.assertEqual(before, self.snapshot())

    @unittest.skipUnless(os.name == 'nt', 'Windows COM shortcut in a temporary test folder')
    def test_real_temporary_startup_link_idempotent_and_exact_ownership(self):
        # No user Startup directory is ever used, and no shortcut is executed.
        directory = self.root / 'fake-startup'; directory.mkdir()
        config = replace(self.config, pythonw=Path(sys.executable))
        untouched = directory / 'other-program.lnk'; untouched.write_bytes(b'unrelated shortcut')
        self.assertFalse(launcher.startup(config, 'check', directory)['enabled'])
        self.assertEqual(list(directory.iterdir()), [untouched])
        self.assertTrue(launcher.startup(config, 'enable', directory)['enabled'])
        created = directory / 'Spoti - telechargements PC.lnk'
        saved = (created.read_bytes(), created.stat().st_mtime_ns)
        self.assertTrue(launcher.startup(config, 'enable', directory)['enabled'])
        self.assertEqual(saved, (created.read_bytes(), created.stat().st_mtime_ns))
        foreign = replace(config, folder=self.root / 'another-pairing')
        self.assertTrue(launcher.startup(foreign, 'check', directory)['conflict'])
        for mode in ('enable', 'disable'):
            with self.assertRaises(subprocess.CalledProcessError): launcher.startup(foreign, mode, directory)
            self.assertEqual(saved, (created.read_bytes(), created.stat().st_mtime_ns))
        self.assertFalse(launcher.startup(config, 'disable', directory)['enabled'])
        self.assertFalse(launcher.startup(config, 'disable', directory)['enabled'])
        self.assertEqual(untouched.read_bytes(), b'unrelated shortcut')
        self.assertEqual(list(directory.iterdir()), [untouched])

    def test_logs_append_and_redact_existing_token(self):
        output = self.config.folder / 'server-output.log'
        output.write_text('old log\n', encoding='utf-8')
        with launcher.logs(self.config): print(self.value['url'])
        value = output.read_text(encoding='utf-8')
        self.assertTrue(value.startswith('old log\n'))
        self.assertNotIn(self.token, value)
        self.assertIn('[association-masquee]', value)

    @unittest.skipUnless(os.name == 'nt', 'Windows child containment')
    def test_owned_child_job_closes_synthetic_descendant_without_external_processes(self):
        script = self.root / 'synthetic_launcher.py'
        marker = self.root / 'child-tick'
        child_script = self.root / 'synthetic_child.py'
        child_script.write_text('import pathlib,time\np=pathlib.Path(' + repr(str(marker)) + ')\n'
                                'while True:\n p.write_text(str(time.time()))\n time.sleep(.05)\n', encoding='utf-8')
        script.write_text('import subprocess,sys,time\nsubprocess.Popen([sys.executable, '
                          + repr(str(child_script)) + '])\ntime.sleep(30)\n', encoding='utf-8')
        config = replace(self.config, pythonw=Path(sys.executable), launcher=script)
        child = launcher.OwnedChild(config, '192.168.1.8')
        try:
            deadline = time.monotonic() + 8
            while not marker.exists() and time.monotonic() < deadline: time.sleep(.05)
            self.assertTrue(marker.exists())
        finally:
            child.close()
        self.assertIsNotNone(child.poll())
        before = marker.stat().st_mtime_ns
        time.sleep(.3)
        self.assertEqual(before, marker.stat().st_mtime_ns)


if __name__ == '__main__':
    unittest.main()
