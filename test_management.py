"""Management regression tests. All files are redirected to temporary directories."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

from test_egress import BASH, SOURCE, posix

ENGINE = re.search(r"<<'PYACCOUNTS'\n(.*?)\nPYACCOUNTS", SOURCE, re.S).group(1)


class AccountTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='l2tp-management-test-')
        self.root = Path(self.temp.name).resolve()
        assert self.root.parent == Path(tempfile.gettempdir()).resolve() and self.root.name.startswith('l2tp-management-test-')
        self.secrets = self.root / 'ppp/chap-secrets'
        self.secrets.parent.mkdir()
        self.foreign = '# original comment\n"other" other-vpn "foreign password" *\n'
        self.secrets.write_text(self.foreign + '"hka1" l2tpd "old pass" *\n', encoding='utf-8', newline='\n')
        self.messages = []
        fake_syslog = types.SimpleNamespace(LOG_INFO=6, openlog=lambda *a: None, syslog=lambda *a: self.messages.append(a[-1]))
        modules = {'syslog': fake_syslog}
        if importlib.util.find_spec('fcntl') is None:
            modules['fcntl'] = types.SimpleNamespace(LOCK_EX=2, flock=lambda *a: None)
        with patch.dict(sys.modules, modules):
            self.engine = {'__name__': 'isolated_accounts'}
            exec(compile(ENGINE, 'embedded-accounts', 'exec'), self.engine)
        for key, value in [('SECRETS', self.secrets), ('BACKUPS', self.root / 'backups'),
                           ('STATE', self.root / 'state'), ('PROC', self.root / 'proc')]:
            self.engine[key] = value
        self.engine['ENDPOINTS'] = self.root / 'endpoints.tsv'
        self.engine['ENDPOINTS'].write_text('118.107.221.60 192.168.18.0/24 192.168.18.1 x\n118.107.221.61 192.168.19.0/24 192.168.19.1 x\n', newline='\n')
        self.engine['STATE'].mkdir(); self.engine['PROC'].mkdir()
        self.fchmod = patch('os.fchmod', lambda *a: None, create=True)
        self.fchmod.start()

    def tearDown(self):
        self.fchmod.stop(); self.temp.cleanup()

    def run_action(self, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output): self.engine['main'](list(args))
        return output.getvalue()

    def rows(self):
        return self.engine['read_accounts'](self.secrets.read_text(encoding='utf-8'))

    def test_list_never_prints_passwords(self):
        output = self.run_action('list')
        self.assertIn('hka1', output)
        self.assertNotIn('old pass', output)
        self.assertNotIn('foreign password', output)

    def test_add_and_password_escaping_preserve_foreign_lines(self):
        password = ' space "quoted" \\ # $special '
        self.run_action('add', '--username', 'hka2', '--password', password)
        self.assertEqual(self.rows()['hka2'][1][2], password)
        self.assertTrue(self.secrets.read_text().startswith(self.foreign))
        self.assertEqual(len(list((self.root / 'backups').glob('*/chap-secrets'))), 1)

    def test_modify_password_and_rename_preserve_remote_and_state(self):
        self.run_action('disable', '--username', 'hka1')
        self.run_action('mod', '--username', 'hka1', '--new-name', 'renamed', '--password', 'new pass')
        self.assertNotIn('hka1', self.rows())
        self.assertEqual(self.rows()['renamed'][1], ['renamed', 'l2tpd-disabled', 'new pass', '*'])

    def test_rename_without_password_retains_password(self):
        self.run_action('mod', '--username', 'hka1', '--new-name', 'renamed')
        self.assertEqual(self.rows()['renamed'][1][2], 'old pass')

    def test_enable_disable(self):
        self.run_action('disable', '--username', 'hka1')
        self.assertEqual(self.rows()['hka1'][1][1], 'l2tpd-disabled')
        self.run_action('enable', '--username', 'hka1')
        self.assertEqual(self.rows()['hka1'][1][1], 'l2tpd')

    def test_batch_add_60_modify_disable_enable_delete(self):
        common = ['--prefix', 'batch', '--start', '1', '--count', '60']
        self.run_action('batch-add', *common, '--password', 'initial')
        self.assertEqual(len(self.rows()), 61)
        self.run_action('batch-mod', *common, '--password', 'changed')
        self.run_action('batch-disable', *common)
        self.assertEqual(self.rows()['batch60'][1][1:3], ['l2tpd-disabled', 'changed'])
        self.run_action('batch-enable', *common)
        self.run_action('batch-del', *common)
        self.assertEqual(list(self.rows()), ['hka1'])
        self.assertTrue(self.secrets.read_text().startswith(self.foreign))

    def test_batch_duplicate_has_no_partial_write_or_backup(self):
        before = self.secrets.read_bytes()
        with self.assertRaises(ValueError): self.run_action('batch-add', '--prefix', 'hka', '--start', '0', '--count', '3', '--password', 'pw')
        self.assertEqual(self.secrets.read_bytes(), before)
        self.assertFalse((self.root / 'backups').exists())

    def test_batch_missing_account_leaves_all_unchanged(self):
        before = self.secrets.read_bytes()
        with self.assertRaises(ValueError): self.run_action('batch-del', '--prefix', 'hka', '--count', '2')
        self.assertEqual(self.secrets.read_bytes(), before)

    def test_duplicate_rename_rejected(self):
        self.run_action('add', '--username', 'hka2', '--password', 'pw')
        before = self.secrets.read_bytes()
        with self.assertRaises(ValueError): self.run_action('mod', '--username', 'hka1', '--new-name', 'hka2')
        self.assertEqual(self.secrets.read_bytes(), before)

    def test_invalid_username_password_and_count(self):
        for args in [('add', '--username', 'bad name', '--password', 'pw'),
                     ('add', '--username', 'valid', '--password', 'bad\tvalue'),
                     ('batch-add', '--prefix', 'a', '--count', '0', '--password', 'pw')]:
            with self.subTest(args=args), self.assertRaises(ValueError): self.run_action(*args)

    def test_password_file(self):
        secret = self.root / 'password'
        secret.write_text('private password\n', newline='\n')
        self.run_action('add', '--username', 'fileuser', '--password-file', str(secret))
        self.assertEqual(self.rows()['fileuser'][1][2], 'private password')

    def test_import_and_export_roundtrip_enabled_disabled(self):
        import_file = self.root / 'import.tsv'
        import_file.write_text('new1\tpass "one" \\\tenabled\nnew2\tsecond\tdisabled\n', newline='\n')
        self.run_action('import', '--file', str(import_file))
        export_file = self.root / 'export.tsv'
        self.run_action('export', '--file', str(export_file), '--with-passwords')
        self.run_action('delete-all')
        self.run_action('import', '--file', str(export_file))
        self.assertEqual(self.rows()['new2'][1][1], 'l2tpd-disabled')
        self.assertEqual(self.rows()['new1'][1][2], 'pass "one" \\')

    def test_import_invalid_or_duplicate_is_atomic(self):
        import_file = self.root / 'invalid.tsv'
        for text in ['new1\tpw\nhka1\tpw\n', 'new1\tpw\nnew1\tpw\n', 'new1\tpw\ninvalid-row\n']:
            import_file.write_text(text, newline='\n')
            before = self.secrets.read_bytes()
            with self.assertRaises(ValueError): self.run_action('import', '--file', str(import_file))
            self.assertEqual(self.secrets.read_bytes(), before)

    def test_default_export_omits_passwords_and_cannot_be_imported(self):
        export_file = self.root / 'public.tsv'
        self.run_action('export', '--file', str(export_file))
        self.assertNotIn('old pass', export_file.read_text())
        with self.assertRaises(ValueError): self.run_action('import', '--file', str(export_file))
        with self.assertRaises(FileExistsError): self.run_action('export', '--file', str(export_file))

    def test_default_delete_does_not_kill_connections(self):
        with patch('os.kill') as kill:
            self.run_action('del', '--username', 'hka1')
        kill.assert_not_called()

    def test_disconnect_checks_pid_start_and_owned_options(self):
        for pid, start, path in [(101, '123', '/etc/ppp/l2tp-endpoints/118.107.221.60.options'),
                                 (102, '999', '/etc/ppp/options.xl2tpd'),
                                 (103, '123', '/etc/ppp/other.options')]:
            (self.root / f'state/{pid}').write_text('hka1 123\n', newline='\n')
            directory = self.root / f'proc/{pid}'
            directory.mkdir()
            (directory / 'stat').write_text(f'{pid} (pppd) ' + ' '.join(['S'] + ['0'] * 18 + [start] + ['0'] * 5))
            (directory / 'cmdline').write_bytes(b'pppd\0file\0' + path.encode() + b'\0')
        with patch('os.kill') as kill:
            self.run_action('disable', '--username', 'hka1', '--disconnect')
        self.assertEqual(kill.call_count, 1)
        self.assertEqual(kill.call_args.args[0], 101)

    def test_delete_all_preserves_unrelated_accounts(self):
        self.run_action('disable', '--username', 'hka1')
        self.run_action('delete-all')
        self.assertEqual(self.secrets.read_text(), self.foreign)

    def test_replace_failure_preserves_original(self):
        before = self.secrets.read_bytes()
        with patch('os.replace', side_effect=OSError('simulated disk error')):
            with self.assertRaises(OSError): self.run_action('add', '--username', 'new', '--password', 'pw')
        self.assertEqual(self.secrets.read_bytes(), before)
        self.assertEqual(list(self.secrets.parent.glob('.chap-secrets.*')), [])

    def test_batch_add_with_sequential_fixed_egress(self):
        self.run_action('batch-add', '--prefix', 'bound', '--count', '2', '--password', 'pw', '--ip-start', '118.107.221.60')
        text = self.secrets.read_text()
        self.assertIn('"bound1" l2tpd "pw" * # l2tp-egress=118.107.221.60', text)
        self.assertIn('"bound2" l2tpd "pw" * # l2tp-egress=118.107.221.61', text)

    def test_binding_survives_password_rename_disable_and_enable(self):
        self.run_action('bind', '--username', 'hka1', '--ip', '118.107.221.60')
        self.run_action('mod', '--username', 'hka1', '--new-name', 'renamed', '--password', 'changed')
        self.run_action('disable', '--username', 'renamed')
        self.run_action('enable', '--username', 'renamed')
        self.assertIn('# l2tp-egress=118.107.221.60', self.secrets.read_text())
        self.run_action('bind', '--username', 'renamed', '--clear-ip')
        self.assertNotIn('# l2tp-egress=', self.secrets.read_text())

    def test_batch_ip_file_and_missing_ip_are_atomic(self):
        self.run_action('add', '--username', 'hka2', '--password', 'pw')
        before = self.secrets.read_bytes()
        with self.assertRaises(ValueError):
            self.run_action('batch-bind', '--prefix', 'hka', '--count', '2', '--ip-start', '118.107.221.61')
        self.assertEqual(self.secrets.read_bytes(), before)
        path = self.root / 'ips.txt'
        path.write_text('118.107.221.61\n118.107.221.60\n', newline='\n')
        self.run_action('batch-bind', '--prefix', 'hka', '--count', '2', '--ip-file', str(path))
        self.assertIn('118.107.221.61', self.run_action('list'))
        self.assertIn('"hka1" l2tpd "old pass" "*" # l2tp-egress=118.107.221.61', self.secrets.read_text())

    def test_binding_export_import_roundtrip(self):
        self.run_action('bind', '--username', 'hka1', '--ip', '118.107.221.61')
        path = self.root / 'bound.tsv'
        self.run_action('export', '--file', str(path), '--with-passwords')
        self.run_action('delete-all')
        self.run_action('import', '--file', str(path))
        self.assertIn('# l2tp-egress=118.107.221.61', self.secrets.read_text())


@unittest.skipUnless(BASH, 'Bash required')
class LifecycleTests(unittest.TestCase):
    def test_connection_limit_updates_preserve_other_configuration(self):
        with tempfile.TemporaryDirectory(prefix='l2tp-limit-test-') as td:
            root = Path(td).resolve()
            assert root.parent == Path(tempfile.gettempdir()).resolve() and root.name.startswith('l2tp-limit-test-')
            fixture = posix(root); binpath = posix(Path(BASH).parent)
            source = SOURCE.replace('/etc/', fixture + '/etc/')
            (root / 'installer.sh').write_text(source, encoding='utf-8', newline='\n')
            (root / 'etc').mkdir()
            (root / 'etc/l2tp-pure.conf').write_text('PORT=9000\nSUBNET=192.168.18.0/24\nMAX_CONNECTIONS=1\nENDPOINT_MODE=1\n', newline='\n')
            driver = '''set -Eeuo pipefail
source "ROOT/installer.sh"
export PATH=BIN:$PATH
chmod() { :; }
logger() { :; }
set_connection_limit 002
'''.replace('ROOT', fixture).replace('BIN', binpath)
            (root / 'driver.sh').write_text(driver, encoding='utf-8', newline='\n')
            result = subprocess.run([BASH, str(root / 'driver.sh')], text=True, encoding='utf-8', errors='replace', capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / 'etc/l2tp-pure.conf').read_text(), 'PORT=9000\nSUBNET=192.168.18.0/24\nENDPOINT_MODE=1\nMAX_CONNECTIONS=2\n')
            backups = list((root / 'etc/l2tp-backup').glob('*/l2tp-pure.conf'))
            self.assertEqual(len(backups), 1)
            self.assertIn('MAX_CONNECTIONS=1', backups[0].read_text())

    def test_uninstall_preserves_foreign_hooks_accounts_and_packages(self):
        self.uninstall_case(False)

    def test_uninstall_keep_accounts(self):
        self.uninstall_case(True)

    def uninstall_case(self, keep):
        with tempfile.TemporaryDirectory(prefix='l2tp-uninstall-test-') as td:
            root = Path(td).resolve()
            assert root.parent == Path(tempfile.gettempdir()).resolve() and root.name.startswith('l2tp-uninstall-test-')
            fixture = posix(root); binpath = posix(Path(BASH).parent)
            source = SOURCE.replace('/etc/', fixture + '/etc/').replace('/usr/local/libexec', fixture + '/libexec')
            source = re.sub(r'^export PATH=.*$', 'export PATH=' + binpath + ':$PATH', source, flags=re.M)
            (root / 'installer.sh').write_text(source, encoding='utf-8', newline='\n')
            for p in ['etc/ppp', 'etc/systemd/system', 'etc/xl2tpd/endpoints', 'etc/ppp/l2tp-endpoints', 'etc/sysctl.d', 'etc/tmpfiles.d', 'libexec']:
                (root / p).mkdir(parents=True, exist_ok=True)
            (root / 'etc/l2tp-pure.conf').write_text('PORT=9000\nSUBNET=192.168.18.0/24\nMAX_CONNECTIONS=2\n', newline='\n')
            (root / 'etc/l2tp-endpoints.tsv').write_text('118.107.221.60 192.168.18.0/24 192.168.18.1 192.168.18.2-192.168.18.254\n', newline='\n')
            (root / 'etc/ppp/chap-secrets').write_text('fixture-accounts\n', newline='\n')
            for name, command in [('auth-up', 'l2tp-limit up'), ('auth-down', 'l2tp-limit down'),
                                  ('ip-up', 'l2tp-egress up "$@"'), ('ip-down', 'l2tp-egress down "$@"')]:
                (root / f'etc/ppp/{name}').write_text(f'#!/bin/sh\n{fixture}/libexec/{command}\necho foreign-hook\n', newline='\n')
            (root / 'etc/xl2tpd/endpoints/118.107.221.60.conf').write_text('managed')
            (root / 'etc/xl2tpd/endpoints/manual.conf').write_text('preserve')
            (root / 'etc/ppp/l2tp-endpoints/118.107.221.60.options').write_text('managed')
            driver = '''set -Eeuo pipefail
source "ROOT/installer.sh"
export PATH=BIN:$PATH
require_linux() { :; }
chmod() { :; }
logger() { :; }
systemctl() {
    printf '%s\n' "$*" >> "ROOT/services.log"
    # A legacy install need not have all newer units; missing units must be skipped.
    [[ "$*" != 'cat l2tp-endpoints.target' ]]
}
iptables() {
    printf '%s\n' "$*" >> "ROOT/firewall.log"
    case " $* " in *' -C '*) return 1;; esac
    return 0
}
accounts() { printf '%s\n' "$*" >> "ROOT/accounts.log"; }
uninstall_l2tp --yes KEEP
'''.replace('ROOT', fixture).replace('BIN', binpath).replace('KEEP', '--keep-accounts' if keep else '')
            (root / 'driver.sh').write_text(driver, encoding='utf-8', newline='\n')
            result = subprocess.run([BASH, str(root / 'driver.sh')], text=True, encoding='utf-8', errors='replace', capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((root / 'etc/l2tp-pure.conf').exists())
            self.assertFalse((root / 'etc/xl2tpd/endpoints/118.107.221.60.conf').exists())
            self.assertTrue((root / 'etc/xl2tpd/endpoints/manual.conf').exists())
            for name in ['auth-up', 'auth-down', 'ip-up', 'ip-down']:
                text = (root / f'etc/ppp/{name}').read_text()
                self.assertIn('echo foreign-hook', text)
                self.assertNotIn('/libexec/l2tp-', text)
            self.assertTrue(list((root / 'etc/l2tp-backup').glob('*/' + fixture.lstrip('/') + '/etc/ppp/chap-secrets')))
            if keep: self.assertFalse((root / 'accounts.log').exists())
            else: self.assertEqual((root / 'accounts.log').read_text().strip(), 'delete-all --disconnect')
            firewall = (root / 'firewall.log').read_text()
            self.assertIn('-X L2TP_PURE_NAT', firewall)
            self.assertNotIn(' -F\n', firewall)
            self.assertNotIn('apt', (root / 'services.log').read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
