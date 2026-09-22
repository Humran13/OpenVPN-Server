#!/usr/bin/env bats
# Unit tests for lib/validate.sh — port/proto/IP/CIDR/hostname/client-name
# validation, including hostile/malformed input.

setup() {
	ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
	source "${ROOT_DIR}/lib/validate.sh"
}

# --- valid_port --------------------------------------------------------
@test "valid_port accepts 1194" { run valid_port 1194; [ "$status" -eq 0 ]; }
@test "valid_port accepts boundary 1" { run valid_port 1; [ "$status" -eq 0 ]; }
@test "valid_port accepts boundary 65535" { run valid_port 65535; [ "$status" -eq 0 ]; }
@test "valid_port rejects 0" { run valid_port 0; [ "$status" -ne 0 ]; }
@test "valid_port rejects 65536" { run valid_port 65536; [ "$status" -ne 0 ]; }
@test "valid_port rejects negative" { run valid_port -1; [ "$status" -ne 0 ]; }
@test "valid_port rejects non-numeric" { run valid_port abc; [ "$status" -ne 0 ]; }
@test "valid_port rejects empty" { run valid_port ""; [ "$status" -ne 0 ]; }
@test "valid_port rejects injection payload" { run valid_port "1194; rm -rf /"; [ "$status" -ne 0 ]; }
@test "valid_port rejects trailing garbage" { run valid_port "1194abc"; [ "$status" -ne 0 ]; }

# --- valid_proto --------------------------------------------------------
@test "valid_proto accepts udp" { run valid_proto udp; [ "$status" -eq 0 ]; }
@test "valid_proto accepts tcp" { run valid_proto tcp; [ "$status" -eq 0 ]; }
@test "valid_proto rejects icmp" { run valid_proto icmp; [ "$status" -ne 0 ]; }
@test "valid_proto rejects empty" { run valid_proto ""; [ "$status" -ne 0 ]; }

# --- valid_ipv4 ----------------------------------------------------------
@test "valid_ipv4 accepts 1.1.1.1" { run valid_ipv4 1.1.1.1; [ "$status" -eq 0 ]; }
@test "valid_ipv4 accepts 0.0.0.0" { run valid_ipv4 0.0.0.0; [ "$status" -eq 0 ]; }
@test "valid_ipv4 accepts 255.255.255.255" { run valid_ipv4 255.255.255.255; [ "$status" -eq 0 ]; }
@test "valid_ipv4 rejects 256.1.1.1" { run valid_ipv4 256.1.1.1; [ "$status" -ne 0 ]; }
@test "valid_ipv4 rejects leading zero octet" { run valid_ipv4 010.1.1.1; [ "$status" -ne 0 ]; }
@test "valid_ipv4 rejects too few octets" { run valid_ipv4 1.1.1; [ "$status" -ne 0 ]; }
@test "valid_ipv4 rejects too many octets" { run valid_ipv4 1.1.1.1.1; [ "$status" -ne 0 ]; }
@test "valid_ipv4 rejects non-numeric" { run valid_ipv4 a.b.c.d; [ "$status" -ne 0 ]; }
@test "valid_ipv4 rejects empty" { run valid_ipv4 ""; [ "$status" -ne 0 ]; }

# --- valid_ipv6 ----------------------------------------------------------
@test "valid_ipv6 accepts ::1" { run valid_ipv6 ::1; [ "$status" -eq 0 ]; }
@test "valid_ipv6 accepts full form" { run valid_ipv6 fd00:cafe:8::1; [ "$status" -eq 0 ]; }
@test "valid_ipv6 rejects plain ipv4" { run valid_ipv6 1.1.1.1; [ "$status" -ne 0 ]; }
@test "valid_ipv6 rejects garbage" { run valid_ipv6 "not:a:valid:address:at:all:really:not"; [ "$status" -ne 0 ]; }
@test "valid_ipv6 rejects empty" { run valid_ipv6 ""; [ "$status" -ne 0 ]; }

# --- valid_cidr4 / valid_cidr6 --------------------------------------------
@test "valid_cidr4 accepts 10.8.0.0/24" { run valid_cidr4 10.8.0.0/24; [ "$status" -eq 0 ]; }
@test "valid_cidr4 accepts /0" { run valid_cidr4 0.0.0.0/0; [ "$status" -eq 0 ]; }
@test "valid_cidr4 accepts /32" { run valid_cidr4 10.0.0.1/32; [ "$status" -eq 0 ]; }
@test "valid_cidr4 rejects /33" { run valid_cidr4 10.0.0.0/33; [ "$status" -ne 0 ]; }
@test "valid_cidr4 rejects missing mask" { run valid_cidr4 10.0.0.0; [ "$status" -ne 0 ]; }
@test "valid_cidr4 rejects bad ip part" { run valid_cidr4 999.0.0.0/24; [ "$status" -ne 0 ]; }
@test "valid_cidr6 accepts fd00::/64" { run valid_cidr6 fd00::/64; [ "$status" -eq 0 ]; }
@test "valid_cidr6 rejects /129" { run valid_cidr6 fd00::/129; [ "$status" -ne 0 ]; }

# --- valid_hostname --------------------------------------------------------
@test "valid_hostname accepts example.com" { run valid_hostname example.com; [ "$status" -eq 0 ]; }
@test "valid_hostname accepts vpn.example.co.uk" { run valid_hostname vpn.example.co.uk; [ "$status" -eq 0 ]; }
@test "valid_hostname accepts bare ipv4" { run valid_hostname 203.0.113.5; [ "$status" -eq 0 ]; }
@test "valid_hostname rejects leading dash label" { run valid_hostname -bad.example.com; [ "$status" -ne 0 ]; }
@test "valid_hostname rejects space" { run valid_hostname "exa mple.com"; [ "$status" -ne 0 ]; }
@test "valid_hostname rejects shell metacharacters" { run valid_hostname 'example.com;rm -rf /'; [ "$status" -ne 0 ]; }
@test "valid_hostname rejects empty" { run valid_hostname ""; [ "$status" -ne 0 ]; }

# --- valid_client_name (security-critical) ---------------------------------
@test "valid_client_name accepts alice" { run valid_client_name alice; [ "$status" -eq 0 ]; }
@test "valid_client_name accepts alice.laptop-2" { run valid_client_name alice.laptop-2; [ "$status" -eq 0 ]; }
@test "valid_client_name accepts alice_desktop" { run valid_client_name alice_desktop; [ "$status" -eq 0 ]; }
@test "valid_client_name rejects path traversal .." { run valid_client_name ..; [ "$status" -ne 0 ]; }
@test "valid_client_name rejects embedded .." { run valid_client_name "foo..bar"; [ "$status" -ne 0 ]; }
@test "valid_client_name rejects path separator" { run valid_client_name "a/b"; [ "$status" -ne 0 ]; }
@test "valid_client_name rejects backslash" { run valid_client_name 'a\b'; [ "$status" -ne 0 ]; }
@test "valid_client_name rejects leading dash (flag injection)" { run valid_client_name "-rf"; [ "$status" -ne 0 ]; }
@test "valid_client_name rejects semicolon injection" { run valid_client_name "alice;rm -rf /"; [ "$status" -ne 0 ]; }
@test "valid_client_name rejects backtick injection" { run valid_client_name 'alice`whoami`'; [ "$status" -ne 0 ]; }
@test "valid_client_name rejects dollar injection" { run valid_client_name 'alice$(whoami)'; [ "$status" -ne 0 ]; }
@test "valid_client_name rejects pipe" { run valid_client_name "alice|cat"; [ "$status" -ne 0 ]; }
@test "valid_client_name rejects space" { run valid_client_name "alice bob"; [ "$status" -ne 0 ]; }
@test "valid_client_name rejects empty" { run valid_client_name ""; [ "$status" -ne 0 ]; }
@test "valid_client_name rejects name over 64 chars" {
	long="$(printf 'a%.0s' $(seq 1 65))"
	run valid_client_name "$long"
	[ "$status" -ne 0 ]
}
@test "valid_client_name accepts name at 64 chars" {
	ok="$(printf 'a%.0s' $(seq 1 64))"
	run valid_client_name "$ok"
	[ "$status" -eq 0 ]
}
@test "valid_client_name rejects single dot" { run valid_client_name "."; [ "$status" -ne 0 ]; }
@test "valid_client_name rejects wildcard" { run valid_client_name "*"; [ "$status" -ne 0 ]; }
@test "valid_client_name rejects quote characters" { run valid_client_name 'ali"ce'; [ "$status" -ne 0 ]; }
@test "valid_client_name rejects newline" { run valid_client_name "$(printf 'a\nb')"; [ "$status" -ne 0 ]; }

# --- misc --------------------------------------------------------------
@test "valid_routing_mode accepts full/split, rejects other" {
	run valid_routing_mode full; [ "$status" -eq 0 ]
	run valid_routing_mode split; [ "$status" -eq 0 ]
	run valid_routing_mode bogus; [ "$status" -ne 0 ]
}
@test "valid_dns_preset accepts known presets" {
	for p in current cloudflare google quad9 custom; do
		run valid_dns_preset "$p"; [ "$status" -eq 0 ]
	done
	run valid_dns_preset opendns; [ "$status" -ne 0 ]
}
@test "yesno_is_yes recognizes y/yes variants only" {
	run yesno_is_yes y; [ "$status" -eq 0 ]
	run yesno_is_yes Yes; [ "$status" -eq 0 ]
	run yesno_is_yes n; [ "$status" -ne 0 ]
	run yesno_is_yes maybe; [ "$status" -ne 0 ]
}
