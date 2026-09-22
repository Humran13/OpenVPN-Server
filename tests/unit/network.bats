#!/usr/bin/env bats
# Unit tests for lib/network.sh — focused on exit-code correctness, since
# install.sh runs under `set -e` and a stray non-zero return from a helper
# aborts the whole install (see net_public_ip regression below).

setup() {
	ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
	source "${ROOT_DIR}/lib/network.sh"
}

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
