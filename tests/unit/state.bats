#!/usr/bin/env bats
# Unit tests for lib/state.sh — persisted KEY="value" state file.

setup() {
	ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
	TMP_ETC="$(mktemp -d)"
	STATE_FILE="${TMP_ETC}/state.conf"
	ETC_DIR="$TMP_ETC"
	source "${ROOT_DIR}/lib/common.sh"
	source "${ROOT_DIR}/lib/state.sh"
}

teardown() { rm -rf "$TMP_ETC"; }

@test "state_set then state_get round-trips a value" {
	state_set PUBLIC_HOST "vpn.example.com"
	run state_get PUBLIC_HOST
	[ "$output" = "vpn.example.com" ]
}

@test "state_get returns default when key is unset" {
	run state_get NOT_SET "fallback"
	[ "$output" = "fallback" ]
}

@test "state_set overwrites an existing key without duplicating lines" {
	state_set ROUTING_MODE full
	state_set ROUTING_MODE split
	run state_get ROUTING_MODE
	[ "$output" = "split" ]
	count="$(grep -c '^ROUTING_MODE=' "$STATE_FILE")"
	[ "$count" -eq 1 ]
}

@test "state_set handles values containing double quotes safely" {
	state_set PUBLIC_HOST 'weird"value'
	run state_get PUBLIC_HOST
	[ "$output" = 'weird"value' ]
}

@test "state_set rejects malformed keys" {
	run state_set "not a key" value
	[ "$status" -ne 0 ]
}

@test "state_unset removes a key" {
	state_set DNS_MODE cloudflare
	state_unset DNS_MODE
	run state_get DNS_MODE "default"
	[ "$output" = "default" ]
}

@test "state file is created with 0600 permissions" {
	state_set PUBLIC_HOST "1.2.3.4"
	perm="$(stat -c '%a' "$STATE_FILE" 2>/dev/null || stat -f '%Lp' "$STATE_FILE")"
	[ "$perm" = "600" ]
}

@test "state persists a comma/pipe-encoded LISTENERS value intact" {
	val="udp1194|udp|1194|ovpn0|4,tcp443|tcp|443|ovpn1|4"
	state_set LISTENERS "$val"
	run state_get LISTENERS
	[ "$output" = "$val" ]
}
