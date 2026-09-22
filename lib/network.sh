#!/usr/bin/env bash
# network.sh — interface/public-IP detection and IP forwarding management.
# All sysctl changes made here are tracked in $ETC_DIR/sysctl.orig so
# uninstall can restore exactly what it changed and nothing else.

if [ -n "${_OVPN_NETWORK_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_NETWORK_LOADED=1

# net_default_iface: the interface carrying the default IPv4 route.
net_default_iface() {
	ip -4 route show default 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1
}

net_default_iface6() {
	ip -6 route show default 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1
}

# net_public_ip: best-effort discovery of the server's public IPv4 address.
# Tries local interface first (works for boxes with a public IP directly
# attached), then falls back to external STUN-less HTTP lookups, which is
# necessary behind NAT/cloud load balancers.
net_public_ip() {
	local iface ip
	iface="$(net_default_iface)"
	if [ -n "$iface" ]; then
		ip="$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
	fi
	if [ -n "$ip" ] && [[ "$ip" != 10.* && "$ip" != 192.168.* && "$ip" != 172.1[6-9].* && "$ip" != 172.2[0-9].* && "$ip" != 172.3[01].* ]]; then
		printf '%s\n' "$ip"
		return 0
	fi
	# Private/NAT'd address: ask an external service.
	local svc
	for svc in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
		local ext
		ext="$(curl -fsSL --max-time 4 "$svc" 2>/dev/null | tr -d '[:space:]')"
		if valid_ipv4 "$ext" 2>/dev/null; then
			printf '%s\n' "$ext"
			return 0
		fi
	done
	# Fall back to whatever local address we found, even if private.
	if [ -n "$ip" ]; then
		printf '%s\n' "$ip"
	fi
	return 0
}

# net_ipv6_usable: 0 if the host has a global IPv6 address AND a default
# IPv6 route AND outbound IPv6 actually works — not just an interface.
net_ipv6_usable() {
	local iface6
	iface6="$(net_default_iface6)"
	[ -n "$iface6" ] || return 1
	ip -6 addr show scope global 2>/dev/null | grep -q "inet6" || return 1
	command -v curl >/dev/null 2>&1 || return 1
	curl -6 -fsS --max-time 3 -o /dev/null "https://ifconfig.co" 2>/dev/null
}

# --- IP forwarding (tracked) ------------------------------------------------
_SYSCTL_TRACK_FILE="${ETC_DIR}/sysctl.orig"
_SYSCTL_DROPIN="/etc/sysctl.d/99-openvpn-server-manager.conf"

net_forwarding_v4_enabled() { [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ]; }
net_forwarding_v6_enabled() { [ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)" = "1" ]; }

# net_enable_forwarding [v4|v6|both]: persist via a dedicated drop-in and
# record the pre-existing runtime value so uninstall can restore it.
net_enable_forwarding() {
	local want="${1:-v4}"
	ensure_dir "$(dirname "$_SYSCTL_TRACK_FILE")" 0700

	{
		echo "# Managed by OpenVPN Server Manager. Do not edit by hand."
		echo "# Enables IP forwarding required to route VPN client traffic."
		[[ "$want" == v4 || "$want" == both ]] && echo "net.ipv4.ip_forward=1"
		[[ "$want" == v6 || "$want" == both ]] && echo "net.ipv6.conf.all.forwarding=1"
	} >"$_SYSCTL_DROPIN"

	if [[ "$want" == v4 || "$want" == both ]]; then
		grep -q '^net.ipv4.ip_forward=' "$_SYSCTL_TRACK_FILE" 2>/dev/null || \
			echo "net.ipv4.ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" >>"$_SYSCTL_TRACK_FILE"
		sysctl -w net.ipv4.ip_forward=1 >/dev/null
	fi
	if [[ "$want" == v6 || "$want" == both ]]; then
		grep -q '^net.ipv6.conf.all.forwarding=' "$_SYSCTL_TRACK_FILE" 2>/dev/null || \
			echo "net.ipv6.conf.all.forwarding=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)" >>"$_SYSCTL_TRACK_FILE"
		sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
	fi
}

# net_restore_forwarding: undo net_enable_forwarding, restoring the exact
# pre-install runtime values (only if we recorded them) and removing our
# drop-in. Never touches other sysctl.d files.
net_restore_forwarding() {
	[ -f "$_SYSCTL_DROPIN" ] && rm -f "$_SYSCTL_DROPIN"
	if [ -f "$_SYSCTL_TRACK_FILE" ]; then
		local k v
		while IFS='=' read -r k v; do
			[ -n "$k" ] || continue
			sysctl -w "${k}=${v}" >/dev/null 2>&1 || true
		done <"$_SYSCTL_TRACK_FILE"
		rm -f "$_SYSCTL_TRACK_FILE"
	fi
	sysctl --system >/dev/null 2>&1 || true
}

# net_tun_available: 0 if /dev/net/tun exists (or can be created) and the
# tun kernel module is loaded/loadable.
net_tun_available() {
	if [ -c /dev/net/tun ]; then return 0; fi
	modprobe tun >/dev/null 2>&1 || true
	[ -c /dev/net/tun ]
}
