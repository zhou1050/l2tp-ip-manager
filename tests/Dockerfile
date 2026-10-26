ARG BASE=debian:12-slim
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d && apt-get update && apt-get install -y --no-install-recommends bash ppp xl2tpd iptables iproute2 util-linux kmod python3 conntrack systemd systemd-sysv procps curl ca-certificates && rm -rf /var/lib/apt/lists/*
CMD ["sleep","infinity"]
