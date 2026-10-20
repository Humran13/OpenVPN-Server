#!/usr/bin/env bats
# Unit tests for lib/network.sh — net_public_ip exit-code correctness (since
# install.sh runs under `set -e` and a stray non-zero return from a helper
# aborts the whole install), and net_port_status, the TCP/UDP port occupancy
# detection used by the setup wizard and the non-interactive installer to
# avoid colliding with other services (or needlessly refusing to reuse our
# own listeners during reconfiguration).

setup() {
	ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
	ETC_DIR="$(mktemp -d)"
	source "${ROOT_DIR}/lib/common.sh"
	source "${ROOT_DIR}/lib/network.sh"

	PROC_DIR="$(mktemp -d)"
	OVPN_PROC_DIR="$PROC_DIR"
}

teardown() { rm -rf "$ETC_DIR" "$PROC_DIR"; }

# --- net_public_ip -----------------------------------------------------
@test "net_public_ip always exits 0, even when nothing is discoverable (regression)" {
	net_default_iface() { echo ""; }
	curl() { return 1; }
	run net_public_ip
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "net_public_ip returns a directly-attached non-private address without calling out" {
	net_default_iface() { echo "eth0"; }
	ip() {
		if [ "$1" = "-4" ]; then echo "inet 203.0.113.7/24 scope global eth0"; fi
	}
	run net_public_ip
	[ "$status" -eq 0 ]
	[ "$output" = "203.0.113.7" ]
}

# --- net_port_status -----------------------------------------------------
_fake_ss_output() {
	# Mimics `ss -ltnp`/`ss -lunp` output shape closely enough for the
	# field-scanning parser (header line + one data line per socket).
	cat
}

@test "net_port_status reports free when ss has no matching line" {
	ss() { _fake_ss_output <<'EOF'
State  Recv-Q Send-Q Local Address:Port   Peer Address:Port Process
LISTEN 0      128    0.0.0.0:22           0.0.0.0:*         users:(("sshd",pid=100,fd=3))
EOF
	}
	export -f ss
	run net_port_status tcp 443
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "net_port_status detects an unrelated foreign process (genuine conflict)" {
	ss() { cat <<'EOF'
State  Recv-Q Send-Q Local Address:Port   Peer Address:Port Process
LISTEN 0      128    0.0.0.0:443          0.0.0.0:*         users:(("nginx",pid=4242,fd=6))
EOF
	}
	export -f ss
	run net_port_status tcp 443
	[ "$status" -eq 2 ]
	[[ "$output" == *"nginx"* ]]
	[[ "$output" == *"4242"* ]]
}

@test "net_port_status recognizes a port held by one of our own listener services" {
	ss() { cat <<'EOF'
State  Recv-Q Send-Q Local Address:Port   Peer Address:Port Process
LISTEN 0      128    0.0.0.0:443          0.0.0.0:*         users:(("openvpn",pid=5050,fd=6))
EOF
	}
	export -f ss
	mkdir -p "${PROC_DIR}/5050"
	echo "0::/system.slice/system-openvpen\\x2dserver\\x2dmanager.slice/openvpn-server-manager@tcp443.service" >"${PROC_DIR}/5050/cgroup"
	run net_port_status tcp 443
	[ "$status" -eq 1 ]
	[[ "$output" == *"openvpn-server-manager@tcp443.service"* ]]
}

@test "net_port_status treats UDP and TCP on the same numeric port independently" {
	ss() {
		case "$1" in
			-ltnp) cat <<'EOF'
State  Recv-Q Send-Q Local Address:Port   Peer Address:Port Process
LISTEN 0      128    0.0.0.0:1194         0.0.0.0:*         users:(("nginx",pid=77,fd=6))
EOF
				;;
			-lunp) ;; # nothing listening on UDP
		esac
	}
	export -f ss
	run net_port_status tcp 1194
	[ "$status" -eq 2 ]
	run net_port_status udp 1194
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "net_port_status does not false-positive on a port number that is a substring of another port" {
	ss() { cat <<'EOF'
State  Recv-Q Send-Q Local Address:Port   Peer Address:Port Process
LISTEN 0      128    0.0.0.0:11943        0.0.0.0:*         users:(("nginx",pid=77,fd=6))
EOF
	}
	export -f ss
	run net_port_status tcp 1194
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "net_port_status returns free (not an error) when ss is unavailable" {
	command() { [ "$1" = "-v" ] && [ "$2" = "ss" ] && return 1; builtin command "$@"; }
	run net_port_status tcp 443
	[ "$status" -eq 0 ]
}
