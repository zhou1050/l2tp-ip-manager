"""Disposable container syslog sink; credentials used by tests are synthetic."""
import pathlib
import socket
path = pathlib.Path('/dev/log')
if path.exists():
    raise RuntimeError('Refusing to replace an existing syslog socket')
sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
sock.bind(str(path))
with open('/tmp/l2tp-test-syslog.log', 'a', buffering=1) as out:
    while True:
        out.write(sock.recv(65536).decode('utf-8', errors='replace').rstrip('\0\n') + '\n')
