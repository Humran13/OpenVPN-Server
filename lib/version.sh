#!/usr/bin/env bash
# version.sh — version reporting.

if [ -n "${_OVPN_VERSION_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_VERSION_LOADED=1

version_show() {
	local bin; bin="$(ovpn_engine_resolve_bin 2>/dev/null)"
	echo "OpenVPN Server Manager v${MANAGER_VERSION}"
	echo "OpenVPN engine (pinned): ${OPENVPN_VERSION}"
	[ -x "$bin" ] && echo "OpenVPN engine (installed): $(ovpn_engine_installed_version "$bin" 2>/dev/null || echo unknown) (${bin})"
	echo "Easy-RSA (pinned): ${EASYRSA_VERSION}"
}
