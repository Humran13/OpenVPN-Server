#!/usr/bin/env bats
# Unit tests for lib/server_config.sh — subnet allocation, netmask math,
# DNS/routing directive generation, and full config-file generation.

setup() {
	ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
	ETC_DIR="$(mktemp -d)"
	OPENVPN_ETC_DIR="$(mktemp -d)"
	STATE_FILE="${ETC_DIR}/state.conf"
	source "${ROOT_DIR}/lib/common.sh"
	source "${ROOT_DIR}/lib/state.sh"
	source "${ROOT_DIR}/lib/server_config.sh"
}

teardown() {
	rm -rf "$ETC_DIR" "$OPENVPN_ETC_DIR" "${PKI_DIR:-}" "${VAR_DIR:-}" "${LOG_DIR:-}"
}

# --- cidr_to_netmask -------------------------------------------------------
@test "cidr_to_netmask /24" { run cidr_to_netmask 24; [ "$output" = "255.255.255.0" ]; }
@test "cidr_to_netmask /16" { run cidr_to_netmask 16; [ "$output" = "255.255.0.0" ]; }
@test "cidr_to_netmask /8"  { run cidr_to_netmask 8;  [ "$output" = "255.0.0.0" ]; }
@test "cidr_to_netmask /32" { run cidr_to_netmask 32; [ "$output" = "255.255.255.255" ]; }
@test "cidr_to_netmask /0"  { run cidr_to_netmask 0;  [ "$output" = "0.0.0.0" ]; }
@test "cidr_to_netmask /25" { run cidr_to_netmask 25; [ "$output" = "255.255.255.128" ]; }
@test "cidr_to_netmask /20" { run cidr_to_netmask 20; [ "$output" = "255.255.240.0" ]; }

# --- subnet allocation (must never collide across listeners) ---------------
@test "srvcfg_subnet_for_index gives distinct /24s per listener" {
	run srvcfg_subnet_for_index 0
	[ "$output" = "10.8.0.0 255.255.255.0" ]
	run srvcfg_subnet_for_index 1
	[ "$output" = "10.8.1.0 255.255.255.0" ]
	run srvcfg_subnet_for_index 256
	[ "$output" = "10.9.0.0 255.255.255.0" ]
}

@test "srvcfg_subnet6_for_index gives distinct ULA prefixes" {
	run srvcfg_subnet6_for_index 0
	[ "$output" = "fd00:cafe:8::/64" ]
	run srvcfg_subnet6_for_index 1
	[ "$output" = "fd00:cafe:9::/64" ]
}

@test "20 listeners never produce a duplicate v4 subnet" {
	seen=""
	for i in $(seq 0 19); do
		s="$(srvcfg_subnet_for_index "$i")"
		case " $seen " in *" $s "*) echo "duplicate: $s"; return 1 ;; esac
		seen="$seen $s"
	done
}

# --- DNS directive generation -----------------------------------------------
@test "_srvcfg_dns_lines: current mode pushes nothing" {
	run _srvcfg_dns_lines current ""
	[ -z "$output" ]
}
@test "_srvcfg_dns_lines: cloudflare pushes both resolvers" {
	run _srvcfg_dns_lines cloudflare ""
	[[ "$output" == *'dhcp-option DNS 1.1.1.1'* ]]
	[[ "$output" == *'dhcp-option DNS 1.0.0.1'* ]]
}
@test "_srvcfg_dns_lines: custom uses provided IPs" {
	run _srvcfg_dns_lines custom "9.9.9.9 149.112.112.112"
	[[ "$output" == *'dhcp-option DNS 9.9.9.9'* ]]
	[[ "$output" == *'dhcp-option DNS 149.112.112.112'* ]]
}
@test "_srvcfg_dns_lines: exits 0 even with only a single custom DNS IP (regression)" {
	# Regression: this function is called under install.sh's `set -e`. A
	# single custom DNS entry (no secondary) used to leave the function's
	# exit status at 1 from its final `[ -n "$d2" ] && ...` line, which
	# would abort the whole install under set -e.
	run _srvcfg_dns_lines custom "9.9.9.9"
	[ "$status" -eq 0 ]
	[[ "$output" == *'dhcp-option DNS 9.9.9.9'* ]]
}

# --- routing directive generation -------------------------------------------
@test "_srvcfg_routing_lines: full tunnel pushes redirect-gateway" {
	run _srvcfg_routing_lines full 4
	[[ "$output" == *'redirect-gateway def1 bypass-dhcp'* ]]
	[[ "$output" != *'redirect-gateway ipv6'* ]]
}
@test "_srvcfg_routing_lines: full tunnel dual-stack also pushes ipv6 gateway" {
	run _srvcfg_routing_lines full 6
	[[ "$output" == *'redirect-gateway ipv6'* ]]
}
@test "_srvcfg_routing_lines: split tunnel pushes only specified networks" {
	run _srvcfg_routing_lines split 4 10.0.0.0/24 192.168.50.0/24
	[[ "$output" == *'push "route 10.0.0.0 255.255.255.0"'* ]]
	[[ "$output" == *'push "route 192.168.50.0 255.255.255.0"'* ]]
	[[ "$output" != *'redirect-gateway'* ]]
}
@test "_srvcfg_routing_lines: split tunnel handles ipv6 CIDR" {
	run _srvcfg_routing_lines split 6 "fd00:abcd::/48"
	[[ "$output" == *'push "route-ipv6 fd00:abcd::/48"'* ]]
}

# --- full server config generation ------------------------------------------
@test "srvcfg_generate writes a syntactically sane UDP server config" {
	PKI_DIR="$(mktemp -d)"
	VAR_DIR="$(mktemp -d)"
	LOG_DIR="$(mktemp -d)"
	DEFAULT_DATA_CIPHERS="AES-256-GCM:CHACHA20-POLY1305"
	DEFAULT_FALLBACK_CIPHER="AES-256-GCM"
	DEFAULT_AUTH_DIGEST="SHA256"
	DEFAULT_TLS_VERSION_MIN="1.2"
	state_set SERVER_CERT_NAME server
	state_set ROUTING_MODE full
	state_set DNS_MODE cloudflare
	srvcfg_generate udp1194 udp 1194 ovpn0 4 0
	conf="${SRV_CONF_DIR}/udp1194.conf"
	[ -f "$conf" ]
	grep -q "^port 1194$" "$conf"
	grep -q "^proto udp$" "$conf"
	grep -q "^dev ovpn0$" "$conf"
	grep -q "^server 10.8.0.0 255.255.255.0$" "$conf"
	grep -q "^dh none$" "$conf"
	grep -q "^tls-crypt " "$conf"
	grep -q "^crl-verify " "$conf"
	grep -q "^data-ciphers AES-256-GCM:CHACHA20-POLY1305$" "$conf"
	grep -q "^explicit-exit-notify 1$" "$conf"
	grep -q 'dhcp-option DNS 1.1.1.1' "$conf"
	grep -q 'redirect-gateway def1 bypass-dhcp' "$conf"
}

@test "srvcfg_generate for TCP omits explicit-exit-notify and uses tcp-server" {
	PKI_DIR="$(mktemp -d)"
	VAR_DIR="$(mktemp -d)"
	LOG_DIR="$(mktemp -d)"
	DEFAULT_DATA_CIPHERS="AES-256-GCM"
	DEFAULT_FALLBACK_CIPHER="AES-256-GCM"
	DEFAULT_AUTH_DIGEST="SHA256"
	DEFAULT_TLS_VERSION_MIN="1.2"
	state_set SERVER_CERT_NAME server
	state_set ROUTING_MODE full
	state_set DNS_MODE current
	srvcfg_generate tcp443 tcp 443 ovpn1 4 1
	conf="${SRV_CONF_DIR}/tcp443.conf"
	grep -q "^proto tcp-server$" "$conf"
	! grep -q "^explicit-exit-notify" "$conf"
	grep -q "^server 10.8.1.0 255.255.255.0$" "$conf"
}

@test "srvcfg_generate dual-stack listener adds server-ipv6 and udp6 proto" {
	PKI_DIR="$(mktemp -d)"
	VAR_DIR="$(mktemp -d)"
	LOG_DIR="$(mktemp -d)"
	DEFAULT_DATA_CIPHERS="AES-256-GCM"
	DEFAULT_FALLBACK_CIPHER="AES-256-GCM"
	DEFAULT_AUTH_DIGEST="SHA256"
	DEFAULT_TLS_VERSION_MIN="1.2"
	state_set SERVER_CERT_NAME server
	state_set ROUTING_MODE full
	state_set DNS_MODE current
	srvcfg_generate udp1194 udp 1194 ovpn0 6 0
	conf="${SRV_CONF_DIR}/udp1194.conf"
	grep -q "^proto udp6$" "$conf"
	grep -q "^server-ipv6 fd00:cafe:8::/64$" "$conf"
}
