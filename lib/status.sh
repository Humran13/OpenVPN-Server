#!/usr/bin/env bash
# status.sh — human-readable server status summary.

if [ -n "${_OVPN_STATUS_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_STATUS_LOADED=1

status_show() {
	os_detect >/dev/null
	local bin installed_ver
	bin="$(ovpn_engine_resolve_bin)"
	installed_ver="$(ovpn_engine_installed_version "$bin" 2>/dev/null || echo unknown)"

	echo "${C_BOLD}OpenVPN Server Manager${C_RESET} v${MANAGER_VERSION}"
	echo "-----------------------------------------------------------"
	printf '%-24s %s\n' "OS:" "$(os_summary)"
	printf '%-24s %s\n' "OpenVPN engine:" "${installed_ver} ($(state_get OPENVPN_INSTALL_METHOD unknown), ${bin})"
	printf '%-24s %s\n' "Easy-RSA:" "${EASYRSA_VERSION}"
	printf '%-24s %s\n' "Public host:" "$(state_get PUBLIC_HOST unset)"
	printf '%-24s %s\n' "Routing mode:" "$(state_get ROUTING_MODE unset)"
	printf '%-24s %s\n' "IP family:" "$(state_get IP_FAMILY unset)"
	printf '%-24s %s\n' "DNS:" "$(state_get DNS_MODE unset)"
	printf '%-24s %s\n' "Firewall backend:" "$(fw_summary)"
	printf '%-24s %s\n' "IPv4 forwarding:" "$(net_forwarding_v4_enabled && echo enabled || echo disabled)"
	printf '%-24s %s\n' "IPv6 forwarding:" "$(net_forwarding_v6_enabled && echo enabled || echo disabled)"
	printf '%-24s %s\n' "DCO available:" "$(ovpn_engine_dco_available && echo yes || echo no)"

	echo
	echo "${C_BOLD}Listeners${C_RESET}"
	local entry name proto port dev family active
	IFS=',' read -ra _entries <<<"$(state_get LISTENERS "")"
	if [ "${#_entries[@]}" -eq 0 ] || [ -z "${_entries[0]}" ]; then
		echo "  (none configured)"
	else
		printf '  %-14s %-6s %-7s %-10s %-8s %s\n' "NAME" "PROTO" "PORT" "DEVICE" "FAMILY" "STATE"
		for entry in "${_entries[@]}"; do
			[ -n "$entry" ] || continue
			IFS='|' read -r name proto port dev family <<<"$entry"
			active="$(systemd_status_instance "$name")"
			printf '  %-14s %-6s %-7s %-10s %-8s %s\n' "$name" "$proto" "$port" "$dev" "$family" "$active"
		done
	fi

	echo
	echo "${C_BOLD}Certificates${C_RESET}"
	printf '%-24s %s\n' "CA expires:" "$(pki_ca_expiry 2>/dev/null || echo 'n/a')"
	printf '%-24s %s\n' "Server cert expires:" "$(pki_server_expiry "$(state_get SERVER_CERT_NAME server)" 2>/dev/null || echo 'n/a')"
	local total valid revoked
	total="$(pki_list_clients | wc -l | tr -d ' ')"
	valid="$(pki_list_clients | awk '$2=="valid"' | wc -l | tr -d ' ')"
	revoked="$(pki_list_clients | awk '$2=="revoked"' | wc -l | tr -d ' ')"
	printf '%-24s %s\n' "Clients:" "${total} total, ${valid} valid, ${revoked} revoked"

	echo
	echo "${C_BOLD}Connected clients${C_RESET}"
	local found=0
	for entry in "${_entries[@]}"; do
		[ -n "$entry" ] || continue
		IFS='|' read -r name proto port dev family <<<"$entry"
		local sf="${VAR_DIR}/status-${name}.log"
		[ -f "$sf" ] || continue
		awk -F',' '/^CLIENT_LIST/{print "  " $2, $3, "(rx:", $6, "tx:", $7")"; f=1} END{exit !f}' "$sf" && found=1
	done
	if [ "$found" -eq 0 ]; then
		echo "  (no active sessions or status files not yet written)"
	fi
	return 0
}
