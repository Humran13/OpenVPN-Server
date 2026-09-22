#!/usr/bin/env bash
# logs.sh — safe log viewing. Never echoes private key material.

if [ -n "${_OVPN_LOGS_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_LOGS_LOADED=1

logs_show() {
	local name="${1:-}" follow="${2:-0}"
	local unit="openvpn-server-manager@*"
	[ -n "$name" ] && unit="openvpn-server-manager@${name}"

	if command -v journalctl >/dev/null 2>&1; then
		if [ "$follow" = "1" ]; then
			journalctl -u "$unit" -f --no-pager
		else
			journalctl -u "$unit" -n 200 --no-pager
		fi
		return 0
	fi

	local f="${LOG_DIR}/${name:-*}.log"
	# shellcheck disable=SC2086
	tail -n 200 ${follow:+-f} $f 2>/dev/null || log_warn "No logs found."
}
