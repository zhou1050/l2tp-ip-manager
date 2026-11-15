"""Real package/PPP/SNAT tests in disposable, isolated Docker containers.

Requires Docker, a host /dev/ppp, and the ppp_async kernel module.
No host networking, host volumes or production service configuration is used.
"""
import argparse
import hashlib
import json
import pathlib
import re
import shlex
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]

def docker(*args, check=True):
    return subprocess.run(['docker', *map(str, args)], check=check, capture_output=True, text=True)

def run(distro):
    image = 'codex-l2tp-test:' + distro
    suffix = str(int(time.time()))
    network = docker('network', 'create', 'codex-l2tp-' + distro + '-' + suffix).stdout.strip()
    containers = []
    report = {'distro': distro, 'checks': [], 'source_sha256': hashlib.sha256((ROOT / 'l2tp2.sh').read_bytes()).hexdigest()}
    def create(role):
        flags = ['--privileged', '--cgroupns=private', '--tmpfs', '/run', '--tmpfs', '/run/lock'] if role == 'server' else ['--cap-add', 'NET_ADMIN', '--device', '/dev/ppp']
        identifier = docker('run', '-d', '--network', network, *flags,
                            '--sysctl', 'net.ipv4.ip_forward=1', '--memory', '768m', '--cpus', '1.5',
                            '--label', 'codex.task=l2tp-validation', image, *(['/sbin/init'] if role == 'server' else [])).stdout.strip()
        assert re.fullmatch('[a-f0-9]{64}', identifier)
        containers.append(identifier)
        docker('exec', identifier, 'mkdir', '-p', '/src/tests')
        files = [ROOT / 'l2tp2.sh', *ROOT.glob('test_*.py'), *(ROOT / 'tests').glob('*.py'), *(ROOT / 'tests').glob('*.sh')]
        for path in files:
            docker('cp', path, identifier + ':/src/' + path.relative_to(ROOT).as_posix())
        return identifier
    def shell(container, command, check=True):
        return docker('exec', container, 'bash', '-lc', command, check=check)
    def background(container, command):
        docker('exec', '-d', container, 'bash', '-lc', command)
    try:
        server, client, observer = create('server'), create('client'), create('observer')
        addresses = {c: docker('inspect', '-f', '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}', c).stdout.strip()
                     for c in containers}
        server_ip, observer_ip = addresses[server], addresses[observer]
        gateway = json.loads(docker('network', 'inspect', network).stdout)[0]['IPAM']['Config'][0]['Gateway']
        for c in containers:
            shell(c, 'ip route show default | grep -q . || ip route add default via ' + gateway)
        shell(server, 'ip addr add 118.107.221.61/25 dev eth0 label eth0:1; ip addr add 118.107.221.60/25 dev eth0')
        shell(client, f'ip route add 118.107.221.0/25 via {server_ip}')
        shell(observer, f'ip route add 118.107.221.0/25 via {server_ip}')
        background(client, 'exec python3 /src/tests/syslog_capture.py')
        for _ in range(30):
            if shell(server, 'test -d /run/systemd/system', check=False).returncode == 0: break
            time.sleep(.1)
        setup = shell(server, 'bash /src/tests/linux_setup.sh')
        report['setup'] = setup.stdout
        report['packages'] = shell(server, "dpkg-query -W -f='${Package} ${Version}\n' ppp xl2tpd iptables python3 systemd conntrack").stdout
        report['os'] = shell(server, 'cat /etc/os-release').stdout
        # Run Python regressions under the distribution's own Python and Bash.
        suite = shell(server, "cd /src && python3 -m unittest discover -s . -p 'test_*.py' -v")
        report['unit_tests'] = suite.stderr
        observer_code = "from http.server import BaseHTTPRequestHandler,HTTPServer\nclass Handler(BaseHTTPRequestHandler):\n def do_GET(self):\n  data=self.client_address[0].encode();self.send_response(200);self.end_headers();self.wfile.write(data)\nHTTPServer(('0.0.0.0',18080),Handler).serve_forever()"
        background(observer, 'exec python3 -c ' + shlex.quote(observer_code))
        lacs = [('a', '118.107.221.61', 'fixed60'), ('b', '118.107.221.60', 'fixed60'),
                ('c', '118.107.221.61', 'unbound'), ('d', '118.107.221.60', 'fixed61')]
        config = '[global]\nport = 1702\nforce userspace = yes\n'
        for name, ingress, user in [*lacs, ('e', '118.107.221.61', 'fixed60'), ('nat', server_ip, 'natfixture')]:
            config += f'\n[lac {name}]\nlns = {ingress}:9000\npppoptfile = /tmp/client-{name}.options\nredial = no\n'
            options = f'noauth\nname {user}\npassword fixture-password\nrefuse-eap\nnoccp\nnoipv6\nmtu 1410\nmru 1410\nnodefaultroute\n'
            shell(client, 'printf %s ' + shlex.quote(options) + f' > /tmp/client-{name}.options')
        shell(client, 'mkdir -p /run/l2tp-client; printf %s ' + shlex.quote(config) + ' > /tmp/client.conf')
        background(client, 'exec xl2tpd -D -c /tmp/client.conf -p /run/l2tp-client/pid -C /run/l2tp-client/control > /tmp/client.log 2>&1')
        for _ in range(30):
            if shell(client, 'test -p /run/l2tp-client/control', check=False).returncode == 0: break
            time.sleep(.1)
        def interfaces():
            data = json.loads(shell(client, 'ip -j addr show').stdout)
            return {d['ifname'] for d in data if d['ifname'].startswith('ppp') and any(a['family'] == 'inet' for a in d.get('addr_info', []))}

        # Reproduce an old SysV service which reports stopped but leaves both
        # the wildcard listener and an authenticated PPP session running.
        before_accounts = shell(server, 'sha256sum /etc/ppp/chap-secrets').stdout
        shell(server, 'systemctl stop l2tp-endpoints.target; systemctl unmask xl2tpd.service; mkdir -p /etc/systemd/system/xl2tpd.service.d')
        override = '[Service]\nExecStop=\nExecStop=/bin/true\nKillMode=none\n'
        shell(server, 'printf %s ' + shlex.quote(override) + ' > /etc/systemd/system/xl2tpd.service.d/fixture.conf')
        shell(server, "sed -i '/^\\[global\\]/a force userspace = yes' /etc/xl2tpd/xl2tpd.conf; systemctl daemon-reload; systemctl start xl2tpd.service")
        shell(client, "printf 'c a\\n' > /run/l2tp-client/control")
        for _ in range(100):
            if interfaces(): break
            time.sleep(.1)
        if not interfaces(): raise AssertionError('Legacy PPP fixture did not connect')
        old_pids = shell(server, "pgrep -x xl2tpd; pgrep -x pppd").stdout.split()
        if len(old_pids) < 2: raise AssertionError('Legacy fixture must contain daemon and live PPP')
        shell(server, 'systemctl stop xl2tpd.service')
        for pid in old_pids:
            if shell(server, f'kill -0 {int(pid)}', check=False).returncode:
                raise AssertionError('Legacy fixture did not leave orphan processes')
        migrated = shell(server, 'bash /src/l2tp2.sh egress')
        if shell(server, 'sha256sum /etc/ppp/chap-secrets').stdout != before_accounts:
            raise AssertionError('Migration changed accounts, passwords or IP bindings')
        listeners = shell(server, "ss -H -ulnp | grep ':9000'").stdout
        if '0.0.0.0:9000' in listeners: raise AssertionError('Migration retained wildcard listener')
        for pid in old_pids:
            args = shell(server, f'cat /proc/{int(pid)}/cmdline', check=False).stdout
            if 'xl2tpd' in args or 'pppd' in args: raise AssertionError('Migration retained an old process')
        if shell(server, 'systemctl is-enabled xl2tpd.service', check=False).stdout.strip() != 'masked':
            raise AssertionError('Legacy service not masked after migration')
        report['checks'].append({'legacy_live_ppp_migration': 'passed', 'orphan_cleanup': 'passed', 'accounts_preserved': True})
        report['migration'] = migrated.stdout
        shell(client, "printf 'd a\\n' > /run/l2tp-client/control")
        for _ in range(100):
            if not interfaces(): break
            time.sleep(.1)
        if interfaces(): raise AssertionError('Legacy client PPP did not close')
        # Rebuild the client tunnel after the old server has been forcibly
        # removed. Reusing its stale tunnel ID only tests xl2tpd retry timeout,
        # not a new dial attempt against the migrated service.
        shell(client, 'pkill -TERM -x xl2tpd || true')
        for _ in range(100):
            if not shell(client, "ss -H -ulnp | grep ':1702'", check=False).stdout: break
            time.sleep(.1)
        else: raise AssertionError('Legacy client listener did not stop')
        shell(client, 'rm -f /run/l2tp-client/control /run/l2tp-client/pid')
        background(client, 'exec xl2tpd -D -c /tmp/client.conf -p /run/l2tp-client/pid -C /run/l2tp-client/control >> /tmp/client.log 2>&1')
        for _ in range(30):
            if shell(client, 'test -p /run/l2tp-client/control', check=False).returncode == 0: break
            time.sleep(.1)
        # Verify enabled per-IP services can recover and dial after a service
        # restart. This does not claim an independent kernel/VM reboot test.
        shell(server, 'systemctl restart l2tp-endpoints.target')
        report['checks'].append({'endpoint_service_restart': 'passed'})
        for name, ingress, user in lacs:
            before = interfaces()
            shell(client, f"printf 'c {name}\\n' > /run/l2tp-client/control")
            added = set()
            for _ in range(100):
                added = interfaces() - before
                if added: break
                time.sleep(.1)
            if not added:
                raise RuntimeError('PPP connection failed: ' + name + '\n' + shell(client, 'cat /tmp/client.log /tmp/l2tp-test-syslog.log').stdout + '\n' + shell(server, 'journalctl -t l2tp-egress -t l2tp-limit -t pppd -t xl2tpd --no-pager -o cat -n 50').stdout)
            interface = sorted(added)[0]
            shell(client, f'ip route replace {observer_ip}/32 dev {interface}')
            actual = shell(client, f'curl --fail --silent --max-time 8 --interface {interface} http://{observer_ip}:18080/').stdout.strip()
            expected = '118.107.221.60' if user == 'fixed60' else '118.107.221.61'
            if actual != expected: raise AssertionError(f'{name}: ingress={ingress}, user={user}, expected={expected}, actual={actual}')
            report['checks'].append(dict(user=user, ingress=ingress, expected_egress=expected, observed_egress=actual, interface=interface))
        server_addresses = json.loads(shell(server, 'ip -j -4 addr show').stdout)
        peers = [a.get('address', a.get('peer')) for d in server_addresses if d['ifname'].startswith('ppp')
                 for a in d.get('addr_info', []) if a['family'] == 'inet']
        if None in peers or len(peers) != 4 or len(set(peers)) != 4:
            raise AssertionError('Concurrent PPP client addresses are not unique: ' + repr(peers))
        report['checks'].append({'concurrent_peer_addresses_unique': True, 'peer_addresses': peers})
        # The same account is already connected twice (a and b). Third login must be rejected.
        shell(client, "printf 'c e\\n' > /run/l2tp-client/control")
        rejected = False
        for _ in range(60):
            if 'event=reject user=fixed60 reason=connection_limit' in shell(server, 'journalctl -t l2tp-egress -t l2tp-limit -t pppd -t xl2tpd --no-pager -o cat').stdout:
                rejected = True; break
            time.sleep(.1)
        if not rejected: raise AssertionError('Third same-account login was not rejected')
        report['checks'].append({'concurrency_limit': 2, 'third_login_rejected': True})
        # Disconnect one call; only that call's forwarding/SNAT state may disappear.
        shell(client, "printf 'd a\\n' > /run/l2tp-client/control")
        remaining = None
        cleanup_started = time.monotonic()
        for _ in range(200):
            rules = shell(server, 'iptables -t nat -S L2TP_PURE_SNAT').stdout
            remaining = sum(line.startswith('-A ') for line in rules.splitlines())
            if remaining == 3: break
            time.sleep(.1)
        if remaining != 3: raise AssertionError(f'Disconnected session SNAT count expected 3, observed {remaining}')
        shell(client, f'ip route replace {observer_ip}/32 dev ppp1')
        if shell(client, f'curl --fail --silent --max-time 8 --interface ppp1 http://{observer_ip}:18080/').stdout.strip() != '118.107.221.60':
            raise AssertionError('Disconnecting one session disturbed another session')
        report['checks'].append({'session_cleanup': 'passed', 'remaining_snat_rules': remaining, 'cleanup_seconds': round(time.monotonic() - cleanup_started, 3)})
        report['snat'] = shell(server, 'iptables -t nat -S L2TP_PURE_SNAT').stdout
        report['syslog'] = shell(server, 'journalctl -t l2tp-egress -t l2tp-limit -t pppd -t xl2tpd --no-pager -o cat').stdout
        removed = shell(server, 'bash /src/l2tp2.sh uninstall --yes --keep-accounts')
        if shell(server, 'iptables -t nat -S L2TP_PURE_SNAT', check=False).returncode == 0:
            raise AssertionError('Uninstall retained managed SNAT chain')
        remaining_accounts = shell(server, 'bash /src/l2tp2.sh account list').stdout
        if not all(user in remaining_accounts for user in ['fixed60', 'fixed61', 'unbound']):
            raise AssertionError('Keep-accounts uninstall removed accounts')
        report['checks'].append({'real_systemd_install': 'passed', 'real_uninstall_keep_accounts': 'passed'})
        report['uninstall'] = removed.stdout
        shell(server, 'ip addr del 118.107.221.61/25 dev eth0; ip addr del 118.107.221.60/25 dev eth0')
        shell(server, 'bash /src/l2tp2.sh install --port 9000 --username natfixture --password fixture-password --count 1 --max-connections 1')
        shell(server, f"ss -H -ulnp | grep -F '{server_ip}:9000'")
        before = interfaces()
        shell(client, "printf 'c nat\\n' > /run/l2tp-client/control")
        for _ in range(100):
            added = interfaces() - before
            if added:
                break
            time.sleep(.1)
        if not added:
            raise AssertionError('Private IPv4 listener did not accept a PPP connection')
        interface = sorted(added)[0]
        shell(client, f'ip route replace {observer_ip}/32 dev {interface}')
        actual = shell(client, f'curl --fail --silent --max-time 8 --interface {interface} http://{observer_ip}:18080/').stdout.strip()
        if actual != server_ip:
            raise AssertionError(f'Private IPv4 SNAT expected {server_ip}, observed {actual}')
        report['checks'].append({'private_ipv4_listener_and_snat': 'passed', 'observed_egress': actual})
        report['result'] = 'passed'
    except Exception as e:
        report['result'] = 'failed'; report['error'] = str(e)
        if containers:
            diagnostic = shell(containers[0], 'journalctl -t l2tp-egress -t l2tp-limit -t pppd -t xl2tpd --no-pager -o cat; iptables -t nat -S L2TP_PURE_SNAT; ip -brief addr; cat /run/l2tp-pure/egress/*.json', check=False)
            report['diagnostic'] = diagnostic.stdout + diagnostic.stderr
        if isinstance(e, subprocess.CalledProcessError):
            report['stdout'], report['stderr'] = e.stdout, e.stderr
    finally:
        for identifier in containers: docker('rm', '-f', identifier, check=False)
        docker('network', 'rm', network, check=False)
    return report

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('distro'); parser.add_argument('--output', required=True)
    args = parser.parse_args()
    report = run(args.distro)
    pathlib.Path(args.output).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'distro': args.distro, 'result': report['result'], 'checks': report['checks'], 'error': report.get('error')}, ensure_ascii=False))
    sys.exit(report['result'] != 'passed')
