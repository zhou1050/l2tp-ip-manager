"""Per-session SNAT rules and cleanup; uses private temporary fixtures."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
from test_egress import SOURCE

SESSION = re.search(r"<<'PYSESSION'\n(.*?)\nPYSESSION", SOURCE, re.S).group(1)

class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='l2tp-session-test-')
        self.root = Path(self.temp.name).resolve()
        assert self.root.parent == Path(tempfile.gettempdir()).resolve() and self.root.name.startswith('l2tp-session-test-')
        modules = {'syslog': types.SimpleNamespace(LOG_INFO=6, openlog=lambda *a: None, syslog=lambda *a: self.events.append(a[-1]))}
        if importlib.util.find_spec('fcntl') is None:
            modules['fcntl'] = types.SimpleNamespace(LOCK_EX=2, flock=lambda *a: None)
        self.events, self.rules, self.commands = [], set(), []
        self.engine = {'__name__': 'session_test'}
        with patch.dict(sys.modules, modules): exec(compile(SESSION, 'embedded-session', 'exec'), self.engine)
        for key, value in [('ROOT', self.root / 'run'), ('PROC', self.root / 'proc'),
                           ('MAP', self.root / 'map'), ('SECRETS', self.root / 'secrets')]: self.engine[key] = value
        self.engine['PROC'].mkdir()
        self.engine['MAP'].write_text('118.107.221.60 192.168.18.0/24 192.168.18.1 pool\n118.107.221.61 192.168.19.0/24 192.168.19.1 pool\n', newline='\n')
        self.engine['SECRETS'].write_text('"hka1" l2tpd "secret # l2tp-egress=1.1.1.1" * # l2tp-egress=118.107.221.60\n"hka2" l2tpd "pw" *\n', newline='\n')
        self.add_process(101, '123')
        self.add_process(102, '124')
        self.process_patch = patch('subprocess.run', side_effect=self.command)
        self.process_patch.start()
        self.address_patch = patch('subprocess.check_output', return_value=json.dumps([{'addr_info': [{'local': '118.107.221.60'}, {'local': '118.107.221.61'}]}]))
        self.address_patch.start()
        self.env_patch = patch.dict(os.environ, {'PPPD_PID': '101', 'PEERNAME': 'hka1'})
        self.env_patch.start()

    def add_process(self, pid, start):
        directory = self.engine['PROC'] / str(pid)
        directory.mkdir(exist_ok=True)
        (directory / 'stat').write_text(f'{pid} (pppd) ' + ' '.join(['S'] + ['0'] * 18 + [start] + ['0'] * 3))
        (directory / 'cmdline').write_bytes(b'pppd\0file\0/etc/ppp/l2tp-endpoints/118.107.221.61.options\0')

    def command(self, args, **kwargs):
        self.commands.append(args)
        if args[0] == 'conntrack': return subprocess.CompletedProcess(args, 1)
        index = next(i for i, a in enumerate(args) if a in ('-A', '-D', '-C'))
        key = tuple(args[:index] + args[index + 1:])
        op = args[index]
        if op == '-C': code = 0 if key in self.rules else 1
        elif op == '-A': self.rules.add(key); code = 0
        else: self.rules.discard(key); code = 0
        return subprocess.CompletedProcess(args, code, '', '')

    def tearDown(self):
        self.env_patch.stop(); self.address_patch.stop(); self.process_patch.stop(); self.temp.cleanup()

    def invoke(self, event, interface='ppp0', remote='192.168.19.2'):
        self.engine['main']([event, interface, 'tty', '0', '192.168.19.1', remote, 'l2tp-egress:118.107.221.61'])

    def test_fixed_egress_differs_from_ingress(self):
        self.invoke('pre-up'); self.invoke('up')
        text = '\n'.join(' '.join(command) for command in self.commands)
        self.assertIn('--to-source 118.107.221.60', text)
        self.assertIn('ingress_ip=118.107.221.61 egress_ip=118.107.221.60', self.events[-1])
        snat = next(i for i, c in enumerate(self.commands) if '-A' in c and 'SNAT' in c)
        allow = next(i for i, c in enumerate(self.commands) if '-A' in c and 'ACCEPT' in c)
        self.assertLess(snat, allow)

    def test_unbound_account_follows_ingress(self):
        os.environ['PEERNAME'] = 'hka2'
        self.invoke('pre-up')
        self.assertEqual(json.loads((self.root / 'run/egress/ppp0.json').read_text())['egress'], '118.107.221.61')

    def test_down_removes_both_rules_and_state(self):
        self.invoke('pre-up'); self.invoke('down')
        self.assertEqual(self.rules, set())
        self.assertFalse((self.root / 'run/egress/ppp0.json').exists())

    def test_late_down_cannot_delete_reused_interface(self):
        self.invoke('pre-up')
        os.environ['PPPD_PID'] = '102'
        self.invoke('down')
        self.assertEqual(len(self.rules), 2)

    def test_active_interface_cannot_be_stolen(self):
        self.invoke('pre-up')
        os.environ['PPPD_PID'] = '102'
        with self.assertRaises(ValueError): self.invoke('pre-up')
        self.assertEqual(len(self.rules), 2)

    def test_two_sessions_do_not_share_rules(self):
        self.invoke('pre-up')
        os.environ['PPPD_PID'] = '102'
        self.invoke('pre-up', 'ppp1', '192.168.19.3')
        self.assertEqual(len(self.rules), 4)
        self.invoke('down', 'ppp1', '192.168.19.3')
        self.assertEqual(len(self.rules), 2)

    def test_snat_failure_never_admits_forwarding(self):
        original = self.command
        def failing(args, **kwargs):
            if '-A' in args and 'SNAT' in args: return subprocess.CompletedProcess(args, 1, '', '')
            return original(args, **kwargs)
        with patch('subprocess.run', side_effect=failing), self.assertRaises(RuntimeError): self.invoke('pre-up')
        self.assertFalse(self.rules)

    def test_missing_egress_or_disabled_user_rejected(self):
        self.engine['SECRETS'].write_text('"hka1" l2tpd-disabled "pw" * # l2tp-egress=118.107.221.60\n', newline='\n')
        with self.assertRaises(ValueError): self.invoke('pre-up')
        self.assertFalse(self.rules)

    def test_up_without_preup_fails_closed(self):
        with self.assertRaises(ValueError): self.invoke('up')
        self.assertFalse(self.rules)

if __name__ == '__main__': unittest.main(verbosity=2)
