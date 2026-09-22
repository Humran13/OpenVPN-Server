#!/usr/bin/env bash
# state.sh — manager state persistence.
#
# State is stored as a plain KEY="value" shell-sourceable file at
# $STATE_FILE (default /etc/openvpn-server-manager/state.conf). This avoids
# a jq/python dependency for something this small, while still being a
# single well-defined source of truth other tools (diagnostics, status,
# backup) all read through the same functions instead of re-parsing.

if [ -n "${_OVPN_STATE_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_STATE_LOADED=1

state_load() {
	if [ -f "$STATE_FILE" ]; then
		# shellcheck disable=SC1090
		. "$STATE_FILE"
	fi
}

# state_set KEY VALUE — idempotently create/update a key in the state file.
state_set() {
	local key="$1" val="$2"
	[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "internal error: bad state key '$key'"
	ensure_dir "$(dirname "$STATE_FILE")" 0700
	local esc="${val//\\/\\\\}"
	esc="${esc//\"/\\\"}"
	local tmp
	tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
	if [ -f "$STATE_FILE" ]; then
		grep -v -E "^${key}=" "$STATE_FILE" >"$tmp" 2>/dev/null || true
	fi
	printf '%s="%s"\n' "$key" "$esc" >>"$tmp"
	chmod 0600 "$tmp"
	mv "$tmp" "$STATE_FILE"
}

state_get() {
	local key="$1" default="${2:-}"
	state_load
	local v
	v="$(eval "printf '%s' \"\${$key:-}\"")"
	[ -n "$v" ] && printf '%s' "$v" || printf '%s' "$default"
}

state_unset() {
	local key="$1"
	[ -f "$STATE_FILE" ] || return 0
	local tmp
	tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
	grep -v -E "^${key}=" "$STATE_FILE" >"$tmp" 2>/dev/null || true
	chmod 0600 "$tmp"
	mv "$tmp" "$STATE_FILE"
}

state_dump() {
	if [ -f "$STATE_FILE" ]; then
		cat "$STATE_FILE"
	fi
	return 0
}
