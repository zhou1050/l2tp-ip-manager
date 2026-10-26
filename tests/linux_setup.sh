#!/bin/bash
# Only run inside the disposable systemd Docker validation server.
set -Eeuo pipefail
bash /src/l2tp2.sh install --port 9000 --username unbound --password fixture-password --count 1 --max-connections 2
bash /src/l2tp2.sh account batch-add --prefix fixed --start 60 --count 2 --password fixture-password --ip-cycle 118.107.221.60,118.107.221.61
systemd-analyze verify /etc/systemd/system/l2tp-endpoint@118.107.221.60.service /etc/systemd/system/l2tp-endpoints.target /etc/systemd/system/l2tp-firewall.service
systemctl is-active l2tp-endpoints.target l2tp-endpoint@118.107.221.60.service l2tp-endpoint@118.107.221.61.service
ss -H -ulnp | grep '118.107.221.*:9000'
