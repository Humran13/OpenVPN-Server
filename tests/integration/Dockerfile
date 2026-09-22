# Systemd-capable Ubuntu test image used for real end-to-end OpenVPN
# install + connection tests. Not used in production; test-only.
ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        systemd systemd-sysv iproute2 curl ca-certificates gnupg \
        iptables openssl net-tools procps tar iputils-ping && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    (find /etc/systemd/system /lib/systemd/system -name '*getty*' -delete 2>/dev/null || true)
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
