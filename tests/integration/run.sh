#!/usr/bin/env bash
# run.sh — real, end-to-end OpenVPN Server Manager integration tests.
#
# Builds a systemd-capable Ubuntu container, installs the manager for real
# (using the actual install.sh, actual OpenVPN engine install strategy, and
# actual PKI), then drives a second container as an OpenVPN client to prove
# an actual TLS tunnel comes up — not a mock.
#
# Usage:
#   BASE_IMAGE=ubuntu:22.04 SCENARIO=udp ./tests/integration/run.sh
#
# SCENARIO one of: udp tcp dual revoke idempotent backup_restore
#                   uninstall_reinstall multi_client
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# On Git-Bash/MSYS (Windows dev machines), rewrite the POSIX-style path to
# a native Windows one so it survives being embedded in a composite
# "SRC:DST:MODE" docker -v argument intact. No-op everywhere else (cygpath
# only exists under MSYS/Cygwin).
if command -v cygpath >/dev/null 2>&1; then
	ROOT_DIR="$(cygpath -m "$ROOT_DIR")"
fi
BASE_IMAGE="${BASE_IMAGE:-ubuntu:22.04}"
SCENARIO="${SCENARIO:-udp}"
RUN_ID="ovpntest-$$-$RANDOM"
NET="${RUN_ID}-net"
SERVER="${RUN_ID}-server"
CLIENT="${RUN_ID}-client"
IMAGE_TAG="ovpn-itest:$(printf '%s' "$BASE_IMAGE" | tr -c 'a-zA-Z0-9' '-')"
KEEP="${KEEP:-0}"

log() { printf '\033[1;36m[itest]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[itest FAIL]\033[0m %s\n' "$*" >&2; RESULT=FAIL; }
pass_step() { printf '\033[1;32m[itest OK]\033[0m %s\n' "$*"; }

RESULT=PASS

cleanup() {
	if [ "$KEEP" = "1" ]; then
		log "KEEP=1 set; leaving containers up: ${SERVER}, ${CLIENT} (network ${NET})"
		return
	fi
	docker rm -f "$SERVER" "$CLIENT" >/dev/null 2>&1 || true
	docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

dexec() { docker exec "$@"; }
dexec_server() { docker exec "$SERVER" bash -lc "$1"; }
dexec_client() { docker exec "$CLIENT" bash -lc "$1"; }

# The client container deliberately does NOT reuse $BASE_IMAGE. It stands
# in for "a normal, reasonably current OpenVPN client machine" (or the
# OpenVPN Connect apps, which are always current) — it is not part of the
# server OS matrix under test. Pinning it to a fixed modern release avoids
# a false failure when testing an older server OS whose own distro archive
# only has a pre-2.5 OpenVPN client that predates directives like
# data-ciphers (added in 2.5.0) that our generated profiles always use.
CLIENT_BASE_IMAGE="${CLIENT_BASE_IMAGE:-ubuntu:24.04}"
CLIENT_IMAGE_TAG="ovpn-itest:$(printf '%s' "$CLIENT_BASE_IMAGE" | tr -c 'a-zA-Z0-9' '-')"

log "Building test image for ${BASE_IMAGE} (cached after first run)..."
docker build -q --build-arg BASE_IMAGE="$BASE_IMAGE" -t "$IMAGE_TAG" "${ROOT_DIR}/tests/integration" >/dev/null
if [ "$CLIENT_BASE_IMAGE" != "$BASE_IMAGE" ]; then
	log "Building client test image for ${CLIENT_BASE_IMAGE} (cached after first run)..."
	docker build -q --build-arg BASE_IMAGE="$CLIENT_BASE_IMAGE" -t "$CLIENT_IMAGE_TAG" "${ROOT_DIR}/tests/integration" >/dev/null
else
	CLIENT_IMAGE_TAG="$IMAGE_TAG"
fi

log "Creating isolated network ${NET}"
docker network create "$NET" >/dev/null

start_container() {
	local name="$1" image="${2:-$IMAGE_TAG}"
	# NOTE: the leading "//" on the cgroup mount source is intentional and
	# harmless on native Linux (the kernel collapses a doubled leading
	# slash to a single one) — it exists purely so this script also works
	# unmodified under Git-Bash/MSYS on Windows dev machines, where a
	# single-slash absolute path gets silently rewritten to a Windows path.
	docker run -d --name "$name" \
		--privileged --cgroupns=host \
		-v //sys/fs/cgroup:/sys/fs/cgroup:rw \
		-v "${ROOT_DIR}:/opt/src:ro" \
		--network "$NET" \
		"$image" >/dev/null
}

wait_systemd() {
	local name="$1" i=0 state
	# 45s is plenty once this is checking the right thing (see below); a
	# freshly-pulled image typically reaches degraded/running within a
	# couple of seconds.
	while [ "$i" -lt 45 ]; do
		# NOTE: must NOT be `docker exec ... | grep ...`. Under this
		# script's `set -o pipefail`, `systemctl is-system-running` exits
		# 1 for the "degraded" state — a state we want to ACCEPT here —
		# and pipefail then makes the whole pipeline report that 1 even
		# when grep matches, so the `if` sees a false condition forever
		# and this loops until timeout no matter what. Capturing the
		# output first and grepping it as a separate, unrelated pipeline
		# avoids that trap.
		state="$(docker exec "$name" systemctl is-system-running 2>/dev/null || true)"
		if printf '%s' "$state" | grep -qE 'running|degraded'; then
			return 0
		fi
		sleep 1; i=$((i + 1))
	done
	return 1
}

log "Starting server container (${SERVER})"
start_container "$SERVER"
wait_systemd "$SERVER" || fail "systemd did not reach 'running' state on server"

SERVER_IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NET}\").IPAddress}}" "$SERVER")"
log "Server container IP: ${SERVER_IP}"

install_server() {
	local mode="$1" extra_env="${2:-}"
	dexec_server "cp -a /opt/src /opt/src-rw && cd /opt/src-rw && \
		OVPN_NONINTERACTIVE=1 OVPN_MODE=${mode} OVPN_PUBLIC_HOST=${SERVER_IP} OVPN_ROUTING=full OVPN_DNS=cloudflare ${extra_env} \
		bash install.sh" || { fail "install.sh failed for mode=${mode}"; return 1; }
}

wait_listener_active() {
	local instance="$1" i=0
	while [ "$i" -lt 20 ]; do
		[ "$(dexec_server "systemctl is-active openvpn-server-manager@${instance}" 2>/dev/null || true)" = "active" ] && return 0
		sleep 1; i=$((i + 1))
	done
	return 1
}

make_client_profile() {
	local name="$1"
	dexec_server "ovpn client add ${name}" || { fail "client add ${name} failed"; return 1; }
	docker cp "${SERVER}:/root/openvpn-clients/${name}.ovpn" "/tmp/${RUN_ID}-${name}.ovpn"
}

start_client_container() {
	start_container "$CLIENT" "$CLIENT_IMAGE_TAG"
	local i=0
	while [ "$i" -lt 15 ]; do
		docker exec "$CLIENT" true >/dev/null 2>&1 && break
		sleep 1; i=$((i + 1))
	done
	dexec_client "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openvpn iputils-ping >/dev/null"
}

connect_client() {
	local profile_name="$1" expect_success="${2:-1}"
	docker cp "/tmp/${RUN_ID}-${profile_name}.ovpn" "${CLIENT}:/root/${profile_name}.ovpn"
	dexec_client "openvpn --config /root/${profile_name}.ovpn --daemon --log /var/log/ovpn-client-${profile_name}.log --writepid /run/ovpn-client-${profile_name}.pid"
	local i=0 got_ip=""
	while [ "$i" -lt 45 ]; do
		got_ip="$(dexec_client "ip -4 addr show 2>/dev/null | awk '/inet 10\\./{print \$2}' | cut -d/ -f1 | head -n1" || true)"
		[ -n "$got_ip" ] && break
		sleep 1; i=$((i + 1))
	done
	if [ "$expect_success" = "1" ]; then
		if [ -z "$got_ip" ]; then
			dexec_client "cat /var/log/ovpn-client-${profile_name}.log" || true
			fail "Client did not receive a tunnel IP for profile ${profile_name}"
			return 1
		fi
		pass_step "Client obtained tunnel IP: ${got_ip}"
		printf '%s\n' "$got_ip"
	else
		if [ -n "$got_ip" ]; then
			fail "Client UNEXPECTEDLY obtained a tunnel IP (${got_ip}) for profile ${profile_name} — should have been rejected"
			return 1
		fi
		pass_step "Client correctly failed to obtain a tunnel IP (expected rejection)"
	fi
}

ping_gateway() {
	local gw="${1:-10.8.0.1}"
	if dexec_client "ping -c 3 -W 2 ${gw} >/tmp/ping.out 2>&1"; then
		pass_step "Ping to VPN gateway ${gw} succeeded"
	else
		dexec_client "cat /tmp/ping.out" || true
		fail "Ping to VPN gateway ${gw} failed"
	fi
}

stop_client() {
	local profile_name="$1"
	dexec_client "[ -f /run/ovpn-client-${profile_name}.pid ] && kill \$(cat /run/ovpn-client-${profile_name}.pid) 2>/dev/null; rm -f /run/ovpn-client-${profile_name}.pid" || true
	sleep 1
}

case "$SCENARIO" in
udp)
	install_server udp
	wait_listener_active udp1194 || fail "udp1194 listener never became active"
	make_client_profile alice
	start_client_container
	connect_client alice 1
	ping_gateway 10.8.0.1
	;;

tcp)
	install_server tcp
	wait_listener_active tcp443 || fail "tcp443 listener never became active"
	make_client_profile alice
	start_client_container
	connect_client alice 1
	ping_gateway 10.8.0.1
	;;

dual)
	install_server dual
	wait_listener_active udp1194 || fail "udp1194 listener never became active"
	wait_listener_active tcp443 || fail "tcp443 listener never became active"
	make_client_profile alice
	start_client_container

	log "Verifying primary (UDP) path works"
	connect_client alice 1
	ping_gateway 10.8.0.1
	stop_client alice

	log "Simulating primary transport outage (stopping UDP listener) and testing TCP fallback"
	dexec_server "systemctl stop openvpn-server-manager@udp1194"
	connect_client alice 1
	ping_gateway 10.8.1.1
	;;

revoke)
	install_server udp
	wait_listener_active udp1194 || fail "udp1194 listener never became active"
	make_client_profile alice
	start_client_container
	connect_client alice 1
	ping_gateway 10.8.0.1
	stop_client alice

	log "Revoking client and confirming CRL blocks reconnection"
	dexec_server "ovpn client revoke alice -y" || fail "client revoke failed"
	sleep 2
	connect_client alice 0
	;;

idempotent)
	install_server udp
	wait_listener_active udp1194 || fail "udp1194 listener never became active"
	rules_before="$(dexec_server "iptables -S | wc -l")"
	ca_before="$(dexec_server "sha256sum /etc/openvpn-server-manager/pki/ca.crt")"
	log "Re-running installer (should be idempotent, no reconfiguration)"
	install_server udp
	wait_listener_active udp1194 || fail "udp1194 listener not active after rerun"
	rules_after="$(dexec_server "iptables -S | wc -l")"
	ca_after="$(dexec_server "sha256sum /etc/openvpn-server-manager/pki/ca.crt")"
	[ "$rules_before" = "$rules_after" ] && pass_step "No duplicate firewall rules after rerun (${rules_before} rules)" || fail "Firewall rule count changed: ${rules_before} -> ${rules_after}"
	[ "$ca_before" = "$ca_after" ] && pass_step "CA was not regenerated on rerun" || fail "CA certificate CHANGED on rerun — PKI was destroyed!"
	make_client_profile alice
	start_client_container
	connect_client alice 1
	ping_gateway 10.8.0.1
	;;

backup_restore)
	install_server udp
	wait_listener_active udp1194 || fail "udp1194 listener never became active"
	make_client_profile alice
	dexec_server "ovpn backup /root/test-backup.tar.gz"
	dexec_server "test -f /root/test-backup.tar.gz" || fail "backup archive was not created"

	log "Mutating/removing project state to simulate disaster"
	dexec_server "rm -rf /etc/openvpn-server-manager/pki"
	dexec_server "ovpn restore /root/test-backup.tar.gz"
	wait_listener_active udp1194 || fail "listener not active after restore"
	dexec_server "test -f /etc/openvpn-server-manager/pki/issued/alice.crt" || fail "client cert missing after restore"

	start_client_container
	connect_client alice 1
	ping_gateway 10.8.0.1
	;;

uninstall_reinstall)
	install_server udp
	wait_listener_active udp1194 || fail "udp1194 listener never became active"
	make_client_profile alice
	start_client_container
	connect_client alice 1
	ping_gateway 10.8.0.1
	stop_client alice

	log "Uninstalling (full)"
	dexec_server "OVPN_ASSUME_YES=1 ovpn uninstall --full -y"
	dexec_server "systemctl list-unit-files | grep -q openvpn-server-manager" && fail "systemd unit still present after uninstall" || pass_step "systemd units removed"
	dexec_server "iptables -S | grep -q ovpn-mgr" && fail "firewall rules still present after uninstall" || pass_step "firewall rules removed"

	log "Reinstalling from scratch"
	install_server udp
	wait_listener_active udp1194 || fail "listener not active after reinstall"
	make_client_profile bob
	connect_client bob 1
	ping_gateway 10.8.0.1
	;;

multi_client)
	install_server udp
	wait_listener_active udp1194 || fail "udp1194 listener never became active"
	make_client_profile alice
	make_client_profile bob
	ca1="$(dexec_server "openssl x509 -noout -serial -in /etc/openvpn-server-manager/pki/issued/alice.crt")"
	ca2="$(dexec_server "openssl x509 -noout -serial -in /etc/openvpn-server-manager/pki/issued/bob.crt")"
	[ "$ca1" != "$ca2" ] && pass_step "alice and bob have distinct certificate serials" || fail "clients share a certificate serial!"
	start_client_container
	connect_client alice 1
	ping_gateway 10.8.0.1
	;;

*)
	echo "Unknown SCENARIO: $SCENARIO" >&2
	exit 2
	;;
esac

echo
if [ "$RESULT" = "PASS" ]; then
	printf '\033[1;32m=== RESULT: PASS (scenario=%s, base=%s) ===\033[0m\n' "$SCENARIO" "$BASE_IMAGE"
	exit 0
else
	printf '\033[1;31m=== RESULT: FAIL (scenario=%s, base=%s) ===\033[0m\n' "$SCENARIO" "$BASE_IMAGE"
	exit 1
fi
