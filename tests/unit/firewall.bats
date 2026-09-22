#!/usr/bin/env bats
# Unit tests for the pure/detectable parts of lib/firewall.sh.
# Rule application itself (iptables/ufw) is exercised for real in the
# Docker-based integration tests, since it needs root + netfilter.

setup() {
	ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
	ETC_DIR="$(mktemp -d)"
	source "${ROOT_DIR}/lib/common.sh"
	source "${ROOT_DIR}/lib/network.sh"
	source "${ROOT_DIR}/lib/firewall.sh"
}

teardown() { rm -rf "$ETC_DIR"; }

@test "fw_ufw_active returns false when ufw is not installed" {
	command() { [ "$1" = "-v" ] && [ "$2" = "ufw" ] && return 1; builtin command "$@"; }
	run fw_ufw_active
	[ "$status" -ne 0 ]
}

@test "fw_ufw_active returns false when ufw exists but is inactive" {
	ufw() { echo "Status: inactive"; }
	export -f ufw
	command() { [ "$1" = "-v" ] && [ "$2" = "ufw" ] && return 0 || builtin command "$@"; }
	run fw_ufw_active
	[ "$status" -ne 0 ]
}

@test "fw_ufw_active returns true when ufw reports active" {
	ufw() { echo "Status: active"; }
	export -f ufw
	command() { [ "$1" = "-v" ] && [ "$2" = "ufw" ] && return 0 || builtin command "$@"; }
	run fw_ufw_active
	[ "$status" -eq 0 ]
}

@test "FW_TUN_PREFIX is 'ovpn' so wildcard interface matching (ovpn+) is stable" {
	[ "$FW_TUN_PREFIX" = "ovpn" ]
}
