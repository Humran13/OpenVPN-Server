#!/usr/bin/env bats
# Unit tests for lib/menu.sh's menu_ask_port — the interactive port-picker
# that must reject ports already held by an unrelated process, but accept
# free ports or ports already owned by one of our own listeners.

setup() {
	ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
	ETC_DIR="$(mktemp -d)"
	source "${ROOT_DIR}/lib/common.sh"
	source "${ROOT_DIR}/lib/validate.sh"
	source "${ROOT_DIR}/lib/menu.sh"
}

teardown() { rm -rf "$ETC_DIR"; }

@test "menu_ask_port accepts a free port on the first try" {
	menu_ask_validated() { echo "443"; }
	net_port_status() { return 0; }
	export -f menu_ask_validated net_port_status
	run menu_ask_port "TCP port" "443" tcp
	[ "$status" -eq 0 ]
	[ "$output" = "443" ]
}

@test "menu_ask_port accepts a port already held by one of our own listeners" {
	menu_ask_validated() { echo "443"; }
	net_port_status() { printf 'our own listener (openvpn-server-manager@tcp443.service, pid 99)\n'; return 1; }
	export -f menu_ask_validated net_port_status
	run menu_ask_port "TCP port" "443" tcp
	[ "$status" -eq 0 ]
	[ "$output" = "443" ]
}

@test "menu_ask_port re-prompts when the port is held by a foreign process, then accepts the next free one" {
	# First call returns the occupied port, every call after returns a free one.
	menu_ask_validated() {
		if [ ! -f "$ASKED_FLAG" ]; then
			touch "$ASKED_FLAG"
			echo "443"
		else
			echo "8443"
		fi
	}
	net_port_status() {
		if [ "$2" = "443" ]; then
			printf 'nginx (pid 4242)\n'
			return 2
		fi
		return 0
	}
	export -f menu_ask_validated net_port_status
	ASKED_FLAG="$(mktemp -u)"
	export ASKED_FLAG
	run menu_ask_port "TCP port" "443" tcp
	rm -f "$ASKED_FLAG"
	[ "$status" -eq 0 ]
	[[ "$output" == *"already in use by nginx"* ]]
	[ "${lines[-1]}" = "8443" ]
}
