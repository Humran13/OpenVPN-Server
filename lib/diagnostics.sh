#!/usr/bin/env bash
# diagnostics.sh — read-only health checks. Never mutates system state;
# `ovpn repair` is the only command allowed to fix what this finds.

if [ -n "${_OVPN_DIAG_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_DIAG_LOADED=1

_DIAG_FAIL=0
_DIAG_WARN=0

_diag_result() {
	local level="$1" msg="$2"
	case "$level" in
		PASS) printf '  %s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$msg" ;;
		WARN) printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$msg"; _DIAG_WARN=$((_DIAG_WARN+1)) ;;
		FAIL) printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$msg"; _DIAG_FAIL=$((_DIAG_FAIL+1)) ;;
	esac
}

diag_run() {
	_DIAG_FAIL=0; _DIAG_WARN=0
	os_detect >/dev/null

	echo "${C_BOLD}OS support${C_RESET}"
	if os_is_supported; then
		_diag_result PASS "Ubuntu ${OS_VERSION_ID} (${OS_CODENAME}) is supported."
	else
		_diag_result FAIL "Ubuntu ${OS_VERSION_ID:-unknown} is not supported (need >= ${MIN_SUPPORTED_UBUNTU_VERSION})."
	fi
	os_is_tested || _diag_result WARN "Ubuntu ${OS_VERSION_ID} (${OS_CODENAME}) was not part of the explicitly tested matrix."
	os_is_eol_warning_needed && _diag_result WARN "Ubuntu 18.04 is EOL outside paid ESM; upgrade for Internet-facing production use."

	echo "${C_BOLD}Architecture${C_RESET}"
	local arch; arch="$(os_arch)"
	[ "$arch" != "unknown" ] && _diag_result PASS "Architecture: ${arch}" || _diag_result WARN "Unrecognized architecture: $(uname -m)"

	echo "${C_BOLD}OpenVPN engine${C_RESET}"
	local bin; bin="$(ovpn_engine_resolve_bin)"
	if [ -x "$bin" ] && "$bin" --version >/dev/null 2>&1; then
		_diag_result PASS "Binary runs: ${bin} ($("$bin" --version 2>/dev/null | head -n1))"
	else
		_diag_result FAIL "OpenVPN binary missing or not runnable: ${bin}"
	fi

	echo "${C_BOLD}TUN device${C_RESET}"
	net_tun_available && _diag_result PASS "/dev/net/tun is available" || _diag_result FAIL "/dev/net/tun is not available"

	echo "${C_BOLD}IP forwarding${C_RESET}"
	net_forwarding_v4_enabled && _diag_result PASS "IPv4 forwarding enabled" || _diag_result FAIL "IPv4 forwarding disabled"
	if [ "$(state_get IP_FAMILY ipv4)" = "dual" ]; then
		net_forwarding_v6_enabled && _diag_result PASS "IPv6 forwarding enabled" || _diag_result WARN "IPv6 forwarding disabled but dual-stack is configured"
	fi

	echo "${C_BOLD}PKI${C_RESET}"
	[ -f "${PKI_DIR}/ca.crt" ] && _diag_result PASS "CA certificate present" || _diag_result FAIL "CA certificate missing (${PKI_DIR}/ca.crt)"
	[ -f "${PKI_DIR}/private/ca.key" ] && { local perm; perm="$(stat -c '%a' "${PKI_DIR}/private/ca.key" 2>/dev/null)"; [ "$perm" = "600" ] && _diag_result PASS "CA private key permissions are 600" || _diag_result WARN "CA private key permissions are ${perm:-unknown}, expected 600"; }
	[ -f "${PKI_DIR}/crl.pem" ] && _diag_result PASS "CRL present" || _diag_result FAIL "CRL missing"
	if [ -f "${PKI_DIR}/ca.crt" ]; then
		local enddate epoch now
		enddate="$(pki_ca_expiry 2>/dev/null)"
		if [ -n "$enddate" ]; then
			epoch="$(date -d "$enddate" +%s 2>/dev/null || echo 0)"
			now="$(date +%s)"
			if [ "$epoch" -gt 0 ] && [ $(( (epoch - now) / 86400 )) -lt 30 ]; then
				_diag_result WARN "CA certificate expires in less than 30 days (${enddate})"
			else
				_diag_result PASS "CA certificate expiry OK (${enddate})"
			fi
		fi
	fi

	echo "${C_BOLD}Systemd units${C_RESET}"
	local entry name any=0
	IFS=',' read -ra _entries <<<"$(state_get LISTENERS "")"
	for entry in "${_entries[@]}"; do
		[ -n "$entry" ] || continue
		any=1
		IFS='|' read -r name _ _ _ _ <<<"$entry"
		local st; st="$(systemd_status_instance "$name")"
		[ "$st" = "active" ] && _diag_result PASS "Listener '${name}' is active" || _diag_result FAIL "Listener '${name}' is ${st}"
	done
	[ "$any" -eq 0 ] && _diag_result WARN "No listeners configured yet."

	echo "${C_BOLD}Listening sockets${C_RESET}"
	for entry in "${_entries[@]}"; do
		[ -n "$entry" ] || continue
		IFS='|' read -r _ proto port _ _ <<<"$entry"
		if ss -lntu 2>/dev/null | awk '{print $5}' | grep -q ":${port}$"; then
			_diag_result PASS "Port ${port}/${proto} is listening"
		else
			_diag_result FAIL "Port ${port}/${proto} is NOT listening"
		fi
	done

	echo "${C_BOLD}Firewall${C_RESET}"
	local fwb; fwb="$(fw_summary)"
	_diag_result PASS "Backend: ${fwb}"

	echo "${C_BOLD}DNS configuration${C_RESET}"
	valid_dns_preset "$(state_get DNS_MODE current)" && _diag_result PASS "DNS mode: $(state_get DNS_MODE current)" || _diag_result WARN "DNS mode unset or invalid"

	echo "${C_BOLD}Port conflicts${C_RESET}"
	local seen="" p2 pt2
	for entry in "${_entries[@]}"; do
		[ -n "$entry" ] || continue
		IFS='|' read -r _ p2 pt2 _ _ <<<"$entry"
		local key="${p2}:${pt2}"
		case " $seen " in *" $key "*) _diag_result FAIL "Duplicate listener ${key}";; *) seen="$seen $key";; esac
	done
	[ -n "$seen" ] && _diag_result PASS "No duplicate proto:port listener pairs"

	echo "${C_BOLD}DCO (Data Channel Offload)${C_RESET}"
	ovpn_engine_dco_available && _diag_result PASS "ovpn-dco kernel module available" || _diag_result WARN "ovpn-dco not available (OpenVPN will run fine without it, just without kernel offload)"

	echo "${C_BOLD}Public IP reachability${C_RESET}"
	local detected; detected="$(net_public_ip 2>/dev/null)"
	local configured; configured="$(state_get PUBLIC_HOST "")"
	if [ -n "$detected" ] && [ -n "$configured" ] && [ "$detected" != "$configured" ] && valid_ipv4 "$configured" 2>/dev/null; then
		_diag_result WARN "Configured public host (${configured}) differs from detected public IP (${detected})"
	else
		_diag_result PASS "Public host: ${configured:-unset} (detected: ${detected:-unknown})"
	fi

	echo "${C_BOLD}Recent OpenVPN service errors${C_RESET}"
	local errs
	errs="$(journalctl -u 'openvpn-server-manager@*' --since '-1 hour' -p err --no-pager 2>/dev/null | wc -l | tr -d ' ')"
	[ "${errs:-0}" -eq 0 ] && _diag_result PASS "No errors in the last hour" || _diag_result WARN "${errs} error line(s) in the last hour — see 'ovpn logs'"

	echo
	echo "-----------------------------------------------------------"
	if [ "$_DIAG_FAIL" -gt 0 ]; then
		log_error "Diagnostics: ${_DIAG_FAIL} FAIL, ${_DIAG_WARN} WARN"
		return 2
	elif [ "$_DIAG_WARN" -gt 0 ]; then
		log_warn "Diagnostics: 0 FAIL, ${_DIAG_WARN} WARN"
		return 1
	else
		log_ok "Diagnostics: all checks passed"
		return 0
	fi
}
