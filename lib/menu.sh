#!/usr/bin/env bash
# menu.sh — plain read-based TUI. Deliberately avoids whiptail/dialog: this
# keeps the manager dependency-free and, crucially, keeps menus working
# reliably when invoked non-interactively via `curl | sudo bash` (input is
# read from /dev/tty via tty_read(), never from the piped stdin).

if [ -n "${_OVPN_MENU_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_MENU_LOADED=1

menu_pause() {
	have_tty || return 0
	tty_read _unused $'\nPress Enter to continue...'
}

# menu_choice "Title" "opt1" "opt2" ... -> sets REPLY_CHOICE to 1-based index
menu_choice() {
	local title="$1"; shift
	local opts=("$@") i
	echo
	echo "${C_BOLD}${title}${C_RESET}"
	for i in "${!opts[@]}"; do
		printf '  %2d) %s\n' "$((i + 1))" "${opts[$i]}"
	done
	local ans
	while :; do
		tty_read ans "Select an option [1-${#opts[@]}]: "
		[[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#opts[@]}" ] && { REPLY_CHOICE="$ans"; return 0; }
		echo "Invalid choice." >&2
	done
}

menu_ask() {
	local prompt="$1" default="${2:-}" ans
	if [ -n "$default" ]; then
		tty_read ans "${prompt} [${default}]: "
		printf '%s\n' "${ans:-$default}"
	else
		tty_read ans "${prompt}: "
		printf '%s\n' "$ans"
	fi
}

menu_ask_validated() {
	local prompt="$1" default="$2" validator="$3" ans
	while :; do
		ans="$(menu_ask "$prompt" "$default")"
		if "$validator" "$ans"; then printf '%s\n' "$ans"; return 0; fi
		echo "Invalid value, try again." >&2
	done
}

# --- install / reconfigure wizard ------------------------------------------
# Populates the LISTENERS, ROUTING_MODE, SPLIT_NETWORKS, IP_FAMILY,
# DNS_MODE, DNS_CUSTOM and PUBLIC_HOST state keys.
wizard_run() {
	echo
	echo "${C_BOLD}${C_CYAN}OpenVPN Server Manager — Setup${C_RESET}"
	echo "-----------------------------------------------------------"

	menu_choice "Connection mode" \
		"UDP only (recommended, port 1194)" \
		"TCP only (useful where UDP is blocked, e.g. port 443)" \
		"Dual: UDP + TCP simultaneously (best compatibility)" \
		"Custom / advanced (choose your own listeners)"
	local mode="$REPLY_CHOICE"

	local listeners=() idx=0
	case "$mode" in
		1)
			local port; port="$(menu_ask_validated "UDP port" "${DEFAULT_UDP_PORT}" valid_port)"
			listeners+=("udp${port}|udp|${port}|ovpn0")
			;;
		2)
			local port; port="$(menu_ask_validated "TCP port" "${DEFAULT_TCP_PORT}" valid_port)"
			listeners+=("tcp${port}|tcp|${port}|ovpn0")
			;;
		3)
			local uport tport
			uport="$(menu_ask_validated "UDP port" "${DEFAULT_UDP_PORT}" valid_port)"
			tport="$(menu_ask_validated "TCP port" "${DEFAULT_TCP_PORT}" valid_port)"
			listeners+=("udp${uport}|udp|${uport}|ovpn0")
			listeners+=("tcp${tport}|tcp|${tport}|ovpn1")
			;;
		4)
			local more=yes n=0
			while yesno_is_yes "$more"; do
				local proto port
				menu_choice "Listener #$((n + 1)) protocol" "UDP" "TCP"
				[ "$REPLY_CHOICE" = "1" ] && proto=udp || proto=tcp
				port="$(menu_ask_validated "Port for this listener" "$([ "$proto" = udp ] && echo "$DEFAULT_UDP_PORT" || echo "$DEFAULT_TCP_PORT")" valid_port)"
				local dup=0 existing
				for existing in "${listeners[@]}"; do
					IFS='|' read -r _ ep epo _ <<<"$existing"
					[ "$ep" = "$proto" ] && [ "$epo" = "$port" ] && dup=1
				done
				if [ "$dup" -eq 1 ]; then
					echo "That protocol/port combination is already configured; skipping duplicate." >&2
				else
					listeners+=("${proto}${port}|${proto}|${port}|ovpn${n}")
					n=$((n + 1))
				fi
				more="$(menu_ask "Add another listener? (y/n)" "n")"
			done
			[ "${#listeners[@]}" -gt 0 ] || die "At least one listener is required."
			;;
	esac

	menu_choice "IP family" \
		"IPv4 only" \
		"Dual-stack IPv4 + IPv6 (only if this host has working outbound IPv6)"
	local ipfam="ipv4" fam_suffix=4
	if [ "$REPLY_CHOICE" = "2" ]; then
		if net_ipv6_usable; then
			ipfam="dual"; fam_suffix=6
		else
			log_warn "IPv6 does not appear to be usable on this host (no working outbound IPv6 route). Falling back to IPv4 only."
		fi
	fi

	local final_listeners=() e
	for e in "${listeners[@]}"; do
		final_listeners+=("${e}|${fam_suffix}")
	done

	menu_choice "Routing mode" \
		"Full tunnel — all client Internet traffic goes through the VPN" \
		"Split tunnel — only specific networks are routed through the VPN"
	local routing="full" split_nets=""
	if [ "$REPLY_CHOICE" = "2" ]; then
		routing="split"
		local more=yes nets=()
		while yesno_is_yes "$more"; do
			local cidr; cidr="$(menu_ask "Network to route through the VPN (CIDR, e.g. 10.0.0.0/24)" "")"
			if valid_cidr4 "$cidr" || valid_cidr6 "$cidr"; then
				nets+=("$cidr")
			else
				echo "Invalid CIDR, skipped." >&2
			fi
			more="$(menu_ask "Add another network? (y/n)" "n")"
		done
		split_nets="${nets[*]}"
	fi

	menu_choice "DNS for clients" "Use this server's current DNS" "Cloudflare (1.1.1.1)" "Google (8.8.8.8)" "Quad9 (9.9.9.9)" "Custom"
	local dns_modes=(current cloudflare google quad9 custom)
	local dns_mode="${dns_modes[$((REPLY_CHOICE - 1))]}"
	local dns_custom=""
	if [ "$dns_mode" = "custom" ]; then
		local d1 d2
		d1="$(menu_ask_validated "Primary DNS IPv4" "1.1.1.1" valid_ipv4)"
		d2="$(menu_ask "Secondary DNS IPv4 (optional)" "1.0.0.1")"
		dns_custom="${d1} ${d2}"
	fi

	local detected; detected="$(net_public_ip 2>/dev/null)"
	local pubhost; pubhost="$(menu_ask_validated "Public hostname or IP clients will connect to" "${detected:-}" valid_hostname)"

	local joined; joined="$(IFS=,; echo "${final_listeners[*]}")"
	state_set LISTENERS "$joined"
	state_set IP_FAMILY "$ipfam"
	state_set ROUTING_MODE "$routing"
	state_set SPLIT_NETWORKS "$split_nets"
	state_set DNS_MODE "$dns_mode"
	state_set DNS_CUSTOM "$dns_custom"
	state_set PUBLIC_HOST "$pubhost"
}

# --- main menu --------------------------------------------------------------
menu_main() {
	while :; do
		menu_choice "OpenVPN Server Manager v${MANAGER_VERSION}" \
			"Server status" \
			"Add client" \
			"List clients" \
			"Show client" \
			"Revoke client" \
			"Renew/reissue client" \
			"Export client profile" \
			"Connection/server settings" \
			"Restart OpenVPN" \
			"Diagnostics" \
			"Logs" \
			"Backup" \
			"Restore" \
			"Update" \
			"Repair installation" \
			"Uninstall" \
			"Exit"
		case "$REPLY_CHOICE" in
			1) status_show ;;
			2) local n; n="$(menu_ask "Client name" "")"; ovpn_cmd_client_add "$n" ;;
			3) pki_list_clients | column -t 2>/dev/null || pki_list_clients ;;
			4) local n; n="$(menu_ask "Client name" "")"; ovpn_cmd_client_show "$n" ;;
			5) local n; n="$(menu_ask "Client name" "")"; confirm "Revoke '${n}'? This immediately blocks their access." && pki_revoke_client "$n" ;;
			6) local n; n="$(menu_ask "Client name" "")"; pki_renew_client "$n" ;;
			7) local n; n="$(menu_ask "Client name" "")"; ovpn_cmd_client_export "$n" "" ;;
			8) menu_settings ;;
			9) systemd_restart_all; log_ok "Restart requested for all listeners." ;;
			10) diag_run ;;
			11) logs_show "" 0 ;;
			12) backup_create ;;
			13) local p; p="$(menu_ask "Path to backup archive" "")"; [ -n "$p" ] && restore_from "$p" ;;
			14) menu_choice "Update" "Manager (this tool)" "OpenVPN engine (upstream)"; [ "$REPLY_CHOICE" = 1 ] && update_manager || update_engine ;;
			15) repair_run ;;
			16) menu_choice "Uninstall" "Remove manager, keep PKI/config backup" "Complete removal (irreversible)" "Cancel"
				case "$REPLY_CHOICE" in
					1) confirm "Remove the manager and services, keeping your PKI/config as a backup?" && uninstall_run keep-data && return 0 ;;
					2) confirm "This PERMANENTLY deletes the CA, all client certificates and config. Continue?" && uninstall_run full && return 0 ;;
				esac
				;;
			17) echo "Goodbye."; return 0 ;;
		esac
		menu_pause
	done
}

menu_settings() {
	echo
	echo "${C_BOLD}Current settings${C_RESET}"
	echo "  Listeners:      $(state_get LISTENERS '(none)')"
	echo "  IP family:      $(state_get IP_FAMILY unset)"
	echo "  Routing mode:   $(state_get ROUTING_MODE unset)"
	echo "  Split networks: $(state_get SPLIT_NETWORKS '(n/a)')"
	echo "  DNS:            $(state_get DNS_MODE unset)"
	echo "  Public host:    $(state_get PUBLIC_HOST unset)"
	menu_choice "Settings" "Reconfigure (runs the setup wizard again)" "Back"
	if [ "$REPLY_CHOICE" = "1" ]; then
		confirm "Reconfiguring will regenerate server configs and restart all listeners. Continue?" || return 0
		wizard_run
		srvcfg_generate_all
		local pubif; pubif="$(fw_public_iface)"
		local subnets=() idx=0 entry proto port
		IFS=',' read -ra _entries <<<"$(state_get LISTENERS "")"
		for entry in "${_entries[@]}"; do
			[ -n "$entry" ] || continue
			IFS='|' read -r _ proto port _ _ <<<"$entry"
			fw_allow_port "$proto" "$port"
			subnets+=("$(srvcfg_subnet_for_index "$idx" | awk '{print $1"/24"}')")
			idx=$((idx + 1))
		done
		fw_apply_forward_and_nat "$pubif" "${subnets[@]}"
		systemctl daemon-reload
		systemd_restart_all
		log_ok "Settings applied."
	fi
}
