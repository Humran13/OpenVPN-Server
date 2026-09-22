#!/usr/bin/env bash
# server_config.sh — generates OpenVPN server-side configuration files.
#
# State encoding (see lib/state.sh):
#   LISTENERS = "name|proto|port|dev|family,name|proto|port|dev|family,..."
#     proto  : udp | tcp
#     family : 4 (IPv4-only) | 6 (dual-stack: binds udp6/tcp6, accepts v4+v6)
#   ROUTING_MODE   = full | split
#   SPLIT_NETWORKS = space-separated CIDRs (only when ROUTING_MODE=split)
#   IP_FAMILY      = ipv4 | dual
#   DNS_MODE       = current|cloudflare|google|quad9|custom
#   DNS_CUSTOM     = "ip1 ip2" (only when DNS_MODE=custom)
#   PUBLIC_HOST    = hostname or IP clients connect to

if [ -n "${_OVPN_SRVCFG_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_SRVCFG_LOADED=1

SRV_CONF_DIR="${OPENVPN_ETC_DIR}/server-manager"

# srvcfg_subnet_for_index N -> "10.8.<N>.0 255.255.255.0" base pool, one
# distinct /24 per listener so client pools never collide across listeners.
srvcfg_subnet_for_index() {
	local idx="$1"
	printf '10.%d.%d.0 255.255.255.0\n' $((8 + idx / 256)) $((idx % 256))
}

srvcfg_subnet6_for_index() {
	local idx="$1"
	printf 'fd00:cafe:%x::/64\n' "$((8 + idx))"
}

_srvcfg_dns_lines() {
	local mode="$1" custom="$2" d1 d2
	case "$mode" in
		cloudflare) d1=1.1.1.1; d2=1.0.0.1 ;;
		google) d1=8.8.8.8; d2=8.8.4.4 ;;
		quad9) d1=9.9.9.9; d2=149.112.112.112 ;;
		custom)
			# shellcheck disable=SC2086 # intentional word-splitting of "ip1 ip2"
			set -- $custom
			d1="${1:-}"; d2="${2:-}" ;;
		current|*) return 0 ;;
	esac
	[ -n "$d1" ] && echo "push \"dhcp-option DNS ${d1}\""
	[ -n "$d2" ] && echo "push \"dhcp-option DNS ${d2}\""
	return 0
}

_srvcfg_routing_lines() {
	local mode="$1" family="$2"; shift 2
	local nets=("$@")
	if [ "$mode" = "full" ]; then
		echo 'push "redirect-gateway def1 bypass-dhcp"'
		[ "$family" = "6" ] && echo 'push "redirect-gateway ipv6"'
		return 0
	fi
	local n net mask
	for n in "${nets[@]}"; do
		[ -n "$n" ] || continue
		if [[ "$n" == *:* ]]; then
			echo "push \"route-ipv6 ${n}\""
		else
			net="${n%/*}"
			mask="$(cidr_to_netmask "${n#*/}")"
			echo "push \"route ${net} ${mask}\""
		fi
	done
}

cidr_to_netmask() {
	local rem="$1"
	local mask=()
	for _ in 1 2 3 4; do
		if [ "$rem" -ge 8 ]; then mask+=(255); rem=$((rem - 8));
		elif [ "$rem" -le 0 ]; then mask+=(0);
		else mask+=($((256 - 2 ** (8 - rem)))); rem=0; fi
	done
	local IFS=.; echo "${mask[*]}"
}

# srvcfg_generate name proto port dev family idx
srvcfg_generate() {
	local name="$1" proto="$2" port="$3" dev="$4" family="$5" idx="$6"
	local proto_directive subnet subnet6
	case "$proto" in
		udp) proto_directive="udp"; [ "$family" = "6" ] && proto_directive="udp6" ;;
		tcp) proto_directive="tcp-server"; [ "$family" = "6" ] && proto_directive="tcp6-server" ;;
		*) die "srvcfg_generate: unknown proto '$proto'" ;;
	esac

	subnet="$(srvcfg_subnet_for_index "$idx")"
	[ "$family" = "6" ] && subnet6="$(srvcfg_subnet6_for_index "$idx")"

	ensure_dir "$SRV_CONF_DIR" 0755
	local conf="${SRV_CONF_DIR}/${name}.conf"
	local tmp; tmp="$(mktemp "${conf}.XXXXXX")"

	local server_name; server_name="$(state_get SERVER_CERT_NAME server)"
	local routing_mode; routing_mode="$(state_get ROUTING_MODE full)"
	local split_nets; split_nets="$(state_get SPLIT_NETWORKS "")"
	local dns_mode; dns_mode="$(state_get DNS_MODE current)"
	local dns_custom; dns_custom="$(state_get DNS_CUSTOM "")"

	{
		echo "# Managed by OpenVPN Server Manager — DO NOT EDIT BY HAND."
		echo "# Regenerate via: sudo ovpn settings apply"
		echo "port ${port}"
		echo "proto ${proto_directive}"
		echo "dev ${dev}"
		echo "dev-type tun"
		echo "topology subnet"
		echo "server ${subnet}"
		[ -n "${subnet6:-}" ] && echo "server-ipv6 ${subnet6}"
		echo "ca ${PKI_DIR}/ca.crt"
		echo "cert ${PKI_DIR}/issued/${server_name}.crt"
		echo "key ${PKI_DIR}/private/${server_name}.key"
		echo "dh none"
		echo "tls-crypt ${PKI_DIR}/tls-crypt.key"
		echo "crl-verify ${SRV_CONF_DIR}/crl.pem"
		echo "data-ciphers ${DEFAULT_DATA_CIPHERS}"
		echo "data-ciphers-fallback ${DEFAULT_FALLBACK_CIPHER}"
		echo "auth ${DEFAULT_AUTH_DIGEST}"
		echo "tls-version-min ${DEFAULT_TLS_VERSION_MIN}"
		echo "remote-cert-tls client"
		echo "persist-key"
		echo "persist-tun"
		echo "keepalive 10 60"
		[ "$proto" = "udp" ] && echo "explicit-exit-notify 1"
		echo "user nobody"
		echo "group nogroup"
		echo "status ${VAR_DIR}/status-${name}.log 10"
		echo "status-version 2"
		echo "log-append ${LOG_DIR}/${name}.log"
		echo "verb 3"
		echo "mute 20"
		_srvcfg_dns_lines "$dns_mode" "$dns_custom"
		# shellcheck disable=SC2086
		_srvcfg_routing_lines "$routing_mode" "$family" $split_nets
	} >"$tmp"

	mv "$tmp" "$conf"
	chmod 0644 "$conf"
	log_ok "Wrote server config: ${conf}"
}

# srvcfg_generate_all: (re)generate every listener's config from state.
srvcfg_generate_all() {
	pki_sync_crl
	local entry name proto port dev family idx=0
	IFS=',' read -ra _entries <<<"$(state_get LISTENERS "")"
	for entry in "${_entries[@]}"; do
		[ -n "$entry" ] || continue
		IFS='|' read -r name proto port dev family <<<"$entry"
		srvcfg_generate "$name" "$proto" "$port" "$dev" "$family" "$idx"
		idx=$((idx + 1))
	done
}

# srvcfg_validate name: briefly start OpenVPN with the generated config and
# confirm it reaches "Initialization Sequence Completed" with no fatal
# errors, then stop it. This is the only reliable way to validate an
# OpenVPN config short of actually running it (there is no standalone
# syntax-check flag that parses every directive).
srvcfg_validate() {
	local name="$1" bin rc
	bin="$(ovpn_engine_resolve_bin)"
	timeout 5 "$bin" --config "${SRV_CONF_DIR}/${name}.conf" --daemon --verb 3 \
		--writepid "/tmp/ovpn-validate-${name}.pid" --log "/tmp/ovpn-validate-${name}.log" >/dev/null 2>&1
	rc=$?
	sleep 1
	if [ -f "/tmp/ovpn-validate-${name}.pid" ]; then
		kill "$(cat "/tmp/ovpn-validate-${name}.pid")" >/dev/null 2>&1 || true
		rm -f "/tmp/ovpn-validate-${name}.pid"
	fi
	local ok=1
	if [ -f "/tmp/ovpn-validate-${name}.log" ]; then
		grep -q "Initialization Sequence Completed" "/tmp/ovpn-validate-${name}.log" && ok=0
		[ "$ok" -ne 0 ] && cat "/tmp/ovpn-validate-${name}.log" >&2
		rm -f "/tmp/ovpn-validate-${name}.log"
	fi
	[ "$rc" -eq 0 ] || ok=1
	return "$ok"
}
