"""Isolated tests; no Linux services, network rules or host configuration are changed."""
import contextlib
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('l2tp2.sh')
SOURCE = SCRIPT.read_text(encoding='utf-8')
PLANNER = re.search(r"<<'PYPLAN'\n(.*?)\nPYPLAN", SOURCE, re.S).group(1)
GIT_BIN = Path(os.environ.get('LOCALAPPDATA', 'C:/Users/Administrator/AppData/Local')).parents[1] / '.cache/codex-runtimes/codex-primary-runtime/dependencies/native/git/usr/bin'
BASH = shutil.which('bash') or (str(GIT_BIN / 'sh.exe') if (GIT_BIN / 'sh.exe').exists() else None)


def posix(path):
    value = str(path).replace('\\', '/')
    return '/' + value[0].lower() + value[2:] if len(value) > 1 and value[1] == ':' else value


class PlannerTests(unittest.TestCase):
    def plan(self, public, base='192.168.18', extra=None, defaults=None, routes=None):
        addresses = [{'ifname': 'eth1', 'addr_info': [
            {'local': ip, 'prefixlen': 24, 'scope': 'global'} for ip in public]}]
        addresses.extend(extra or [])
        def fake(cmd, **kwargs):
            if cmd[3] == 'addr': return json.dumps(addresses)
            if cmd[-1] == 'default': return json.dumps(defaults if defaults is not None else [{'dev': 'eth1'}])
            return json.dumps(routes or [])
        out, err = io.StringIO(), io.StringIO()
        rc = 0
        with patch('subprocess.check_output', side_effect=fake), patch.object(sys, 'argv', ['plan', base]), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try: exec(compile(PLANNER, 'embedded-plan', 'exec'), {})
            except SystemExit as e: rc = e.code
        return rc, out.getvalue(), err.getvalue()

    def test_distinct_ingress_and_pool(self):
        rc, out, _ = self.plan(['61.15.33.11', '61.15.33.10'])
        self.assertEqual(rc, 0)
        self.assertEqual(out.splitlines(), [
            '61.15.33.10\t192.168.18.0/24\t192.168.18.1\t192.168.18.2-192.168.18.254',
            '61.15.33.11\t192.168.19.0/24\t192.168.19.1\t192.168.19.2-192.168.19.254'])

    def test_253_ingresses_have_unique_private_pools(self):
        rc, out, _ = self.plan([f'61.15.33.{i}' for i in range(2, 255)])
        self.assertEqual(rc, 0)
        pools = [line.split()[1] for line in out.splitlines()]
        self.assertEqual(len(set(pools)), 253)
        self.assertTrue(all(ipaddress.ip_network(p).subnet_of(ipaddress.ip_network('192.168.0.0/16')) for p in pools))

    def test_debian_primary_alias_and_secondary_25_addresses(self):
        extra = [{'ifname': 'enp4s0', 'addr_info': [
            {'local': '118.107.221.61', 'prefixlen': 25, 'scope': 'global', 'label': 'enp4s0:1'},
            {'local': '118.107.221.60', 'prefixlen': 25, 'scope': 'global', 'secondary': True},
        ]}, {'ifname': 'ppp0', 'addr_info': [
            {'local': '192.168.18.1', 'prefixlen': 32, 'scope': 'global', 'peer': '192.168.18.2'},
        ]}]
        rc, out, err = self.plan([], extra=extra, defaults=[{'dev': 'enp4s0', 'gateway': '118.107.221.1'}],
                                 routes=[{'dst': '118.107.221.0/25', 'dev': 'enp4s0'},
                                         {'dst': '192.168.18.2/32', 'dev': 'ppp0'}])
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.splitlines(), [
            '118.107.221.60\t192.168.18.0/24\t192.168.18.1\t192.168.18.2-192.168.18.254',
            '118.107.221.61\t192.168.19.0/24\t192.168.19.1\t192.168.19.2-192.168.19.254'])

    def test_no_public_address_rejected(self):
        self.assertNotEqual(self.plan(['10.0.0.2'])[0], 0)

    def test_multiple_default_routes_rejected(self):
        self.assertNotEqual(self.plan(['61.15.33.10'], defaults=[{'dev': 'eth1'}, {'dev': 'eth2'}])[0], 0)

    def test_wrong_uplink_rejected(self):
        self.assertNotEqual(self.plan(['61.15.33.10'], defaults=[{'dev': 'eth0'}])[0], 0)

    def test_address_conflict_rejected(self):
        extra = [{'ifname': 'eth0', 'addr_info': [{'local': '192.168.18.8', 'prefixlen': 24}]}]
        rc, out, _ = self.plan(['61.15.33.10'], extra=extra)
        self.assertNotEqual(rc, 0)
        self.assertEqual(out, '')

    def test_route_conflict_rejected(self):
        self.assertNotEqual(self.plan(['61.15.33.10'], routes=[{'dst': '192.168.18.0/24', 'dev': 'eth0'}])[0], 0)

    def test_existing_ppp_routes_do_not_prevent_migration(self):
        rc, _, _ = self.plan(['61.15.33.10'], routes=[{'dst': '192.168.18.2/32', 'dev': 'ppp0'}])
        self.assertEqual(rc, 0)

    def test_private_prefix_rejected_if_public(self):
        self.assertNotEqual(self.plan(['61.15.33.10'], base='8.8.8')[0], 0)


@unittest.skipUnless(BASH, 'Bash required')
class ShellTests(unittest.TestCase):
    def test_script_and_embedded_shell_syntax(self):
        subprocess.run([BASH, '-n', str(SCRIPT)], check=True, capture_output=True)
        for marker in ['HOOK', 'FW', 'EGRESS']:
            body = re.search(r"<<'" + marker + r"'\n(.*?)\n" + marker, SOURCE, re.S).group(1)
            subprocess.run([BASH, '-n'], input=body, text=True, check=True, capture_output=True)

    def test_render_hooks_nat_logs_and_migration(self):
        with tempfile.TemporaryDirectory(prefix='l2tp-egress-test-') as td:
            root = Path(td).resolve()
            assert root.parent == Path(tempfile.gettempdir()).resolve() and root.name.startswith("l2tp-egress-test-")
            fixture = posix(root)
            # Redirect every generated /etc and libexec path into a temporary fixture.
            script = SOURCE.replace('/etc/', fixture + '/etc/').replace('/usr/local/libexec', fixture + '/libexec').replace('/run/l2tp-pure', fixture + '/run/l2tp-pure')
            binpath = posix(Path(BASH).parent)
            script = re.sub(r'^export PATH=.*$', 'export PATH=' + binpath + ':$PATH', script, flags=re.M)
            (root / 'installer.sh').write_text(script, encoding='utf-8', newline='\n')
            for path in ['etc/ppp', 'etc/systemd/system', 'etc/xl2tpd', 'libexec']:
                (root / path).mkdir(parents=True)
            (root / 'etc/ppp/options.xl2tpd').write_text('auth\nrequire-mschap-v2\nipcp-accept-remote\nipparam l2tp-pure\n', encoding='utf-8', newline='\n')
            (root / 'etc/ppp/chap-secrets').write_text('"hka1" l2tpd "fixture-secret" *\n', encoding='utf-8', newline='\n')
            (root / 'etc/l2tp-pure.conf').write_text('PORT=9000\nSUBNET=192.168.18.0/24\nMAX_CONNECTIONS=2\n', encoding='utf-8', newline='\n')
            (root / 'etc/ppp/ip-up').write_text('#!/bin/sh\necho original-up-hook\nexit 0\n', encoding='utf-8', newline='\n')
            (root / 'etc/ppp/auth-up').write_text('#!/bin/sh\necho original-auth-hook\nexit 0\n', encoding='utf-8', newline='\n')
            (root / 'plan.tsv').write_text('61.15.33.10\t192.168.18.0/24\t192.168.18.1\t192.168.18.2-192.168.18.254\n61.15.33.11\t192.168.19.0/24\t192.168.19.1\t192.168.19.2-192.168.19.254\n', encoding='utf-8', newline='\n')
            driver = '''set -Eeuo pipefail
source "ROOT/installer.sh"
export PATH=BIN:$PATH
# Windows cannot verify Linux modes; services and iptables are deliberately mocked.
chmod() { :; }
flock() { :; }
conntrack() { return 1; }
logger() { printf '%s\n' "$*" >> "ROOT/events.log"; }
iptables() {
    printf '%s\n' "$*" >> "ROOT/iptables.log"
    case " $* " in *' -C '*) return 1;; esac
    return 0
}
systemctl() { printf '%s\n' "$*" >> "ROOT/systemctl.log"; }
ss() { printf 'UNCONN 0 0 61.15.33.10:9000 *:* users:(("xl2tpd"))\nUNCONN 0 0 61.15.33.11:9000 *:* users:(("xl2tpd"))\n'; }
install_hooks
install_egress_logger
configure_endpoints "ROOT/plan.tsv" 9000
install_firewall
install_hooks
install_egress_logger
source "ROOT/libexec/l2tp-firewall"
start_endpoints 9000
require_linux() { :; }
journalctl() { printf '%s\n' "$*" >> "ROOT/journalctl.log"; }
show_logs --no-follow --lines 25
show_logs
# Migrate without touching accounts, using a deterministic ingress plan.
plan_endpoints() { cat "ROOT/plan.tsv"; }
check_firewall_support() { :; }
check_port() { :; }
migrate_egress
'''.replace('ROOT', fixture).replace('BIN', binpath)
            (root / 'driver.sh').write_text(driver, encoding='utf-8', newline='\n')
            result = subprocess.run([BASH, str(root / 'driver.sh')], text=True, encoding='utf-8', errors='replace', capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + '\n' + result.stderr)
            for ip, subnet in [('61.15.33.10', '192.168.18'), ('61.15.33.11', '192.168.19')]:
                config = (root / f'etc/xl2tpd/endpoints/{ip}.conf').read_text()
                self.assertIn(f'listen-addr = {ip}', config)
                self.assertIn('pass peer = no', config)
                self.assertIn(f'ip range = {subnet}.2-{subnet}.254', config)
                options = (root / f'etc/ppp/l2tp-endpoints/{ip}.options').read_text()
                self.assertIn(f'ipparam l2tp-egress:{ip}', options)
                self.assertNotIn('ipcp-accept-remote', options)
            up = (root / 'etc/ppp/ip-up').read_text()
            self.assertIn('echo original-up-hook', up)
            self.assertEqual(up.count('l2tp-egress up "$@"'), 1)
            self.assertIn('echo original-auth-hook', (root / 'etc/ppp/auth-up').read_text())
            self.assertTrue((root / 'etc/ppp/ip-down').read_text().startswith('#!/bin/sh\n'))
            nat = (root / 'iptables.log').read_text()
            self.assertIn('-j L2TP_PURE_SNAT', nat)
            self.assertIn('-s 192.168.18.0/24 -j L2TP_PURE_SESSION', nat)
            self.assertIn('-s 192.168.18.0/24 -j DROP', nat)
            self.assertNotIn('-j MASQUERADE', nat)
            journal = (root / 'journalctl.log').read_text().splitlines()
            self.assertIn('-n 25', journal[0])
            self.assertNotIn(' -f', journal[0])
            self.assertTrue(journal[1].endswith(' -f'))
            self.assertEqual((root / 'etc/ppp/chap-secrets').read_text(), '"hka1" l2tpd "fixture-secret" *\n')
            self.assertIn('disable --now xl2tpd.service', (root / 'systemctl.log').read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
