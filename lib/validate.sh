#!/usr/bin/env bash
# validate.sh — strict input validation. Every function returns 0 (valid) /
# 1 (invalid) and never eval's, sources, or shells-out to user-supplied data.

if [ -n "${_OVPN_VALIDATE_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_VALIDATE_LOADED=1

valid_port() {
	local p="$1"
	[[ "$p" =~ ^[0-9]+$ ]] || return 1
	[ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

valid_proto() {
	case "$1" in
		udp|tcp|udp4|tcp4|udp6|tcp6) return 0 ;;
		*) return 1 ;;
	esac
}

valid_ipv4() {
	local ip="$1" a b c d o
	[[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
	IFS='.' read -r a b c d <<<"$ip"
	for o in "$a" "$b" "$c" "$d"; do
		[ "$o" -le 255 ] || return 1
		[ "${#o}" -gt 1 ] && [ "${o:0:1}" = "0" ] && return 1
	done
	return 0
}

valid_ipv6() {
	local ip="$1"
	[[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] || return 1
	[[ "$ip" == *:* ]] || return 1
	# Reject obviously malformed triple-colon etc; delegate the fine-grained
	# check to the kernel's own parser when available.
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$ip" <<'PY' 2>/dev/null
import socket, sys
try:
    socket.inet_pton(socket.AF_INET6, sys.argv[1])
except OSError:
    sys.exit(1)
PY
		return $?
	fi
	[[ "$ip" != *":::"* ]]
}

valid_cidr4() {
	local cidr="$1" ip mask
	[[ "$cidr" == */* ]] || return 1
	ip="${cidr%/*}"; mask="${cidr#*/}"
	valid_ipv4 "$ip" || return 1
	[[ "$mask" =~ ^[0-9]+$ ]] || return 1
	[ "$mask" -ge 0 ] && [ "$mask" -le 32 ]
}

valid_cidr6() {
	local cidr="$1" ip mask
	[[ "$cidr" == */* ]] || return 1
	ip="${cidr%/*}"; mask="${cidr#*/}"
	valid_ipv6 "$ip" || return 1
	[[ "$mask" =~ ^[0-9]+$ ]] || return 1
	[ "$mask" -ge 0 ] && [ "$mask" -le 128 ]
}

# RFC 1123 hostname (also accepts bare IPv4 as a "hostname" for --public-ip use)
valid_hostname() {
	local h="$1"
	[ -n "$h" ] && [ "${#h}" -le 253 ] || return 1
	valid_ipv4 "$h" && return 0
	[[ "$h" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

# Client / listener identifier: alnum, dash, underscore, dot; 1-64 chars.
# Deliberately excludes anything that could traverse paths or break shell
# quoting/argument parsing (spaces, /, \, ;, |, $, `, quotes, leading '-').
valid_client_name() {
	local n="$1"
	[ -n "$n" ] || return 1
	[ "${#n}" -le 64 ] || return 1
	[[ "$n" == -* ]] && return 1
	[[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
	# Reject path-traversal / dotfile tricks explicitly even though the
	# character class above already blocks '/'.
	case "$n" in
		.|..|*..*) return 1 ;;
	esac
	return 0
}

valid_routing_mode() {
	case "$1" in
		full|split) return 0 ;;
		*) return 1 ;;
	esac
}

valid_ip_family() {
	case "$1" in
		ipv4|dual) return 0 ;;
		*) return 1 ;;
	esac
}

valid_dns_preset() {
	case "$1" in
		current|cloudflare|google|quad9|custom) return 0 ;;
		*) return 1 ;;
	esac
}

valid_yesno() {
	case "$1" in
		y|Y|yes|Yes|YES|n|N|no|No|NO) return 0 ;;
		*) return 1 ;;
	esac
}

yesno_is_yes() {
	case "$1" in
		y|Y|yes|Yes|YES) return 0 ;;
		*) return 1 ;;
	esac
}

# Guards against command-injection-style payloads being accepted anywhere
# validation is the only gate (defense in depth; callers must still avoid
# eval/unquoted expansion regardless of this check).
valid_no_shell_meta() {
	local s="$1"
	[[ "$s" != *[\;\&\|\$\`\\\<\>\(\)\{\}\"\'\!\*\?\[\]\~\ ]* ]]
}
