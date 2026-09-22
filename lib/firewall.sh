#!/usr/bin/env bash
# firewall.sh — safe, tracked firewall rule management.
#
# Design goals (see project scope guard):
#   - NEVER flush or replace the user's existing firewall.
#   - Track every rule THIS project adds so uninstall removes exactly those
#     rules and nothing else.
#   - Coexist with UFW when it is active (inject via before.rules, the
#     standard supported extension point, instead of bare iptables -A which
#     `ufw reload`/reboot would silently discard).
#   - Otherwise manage plain iptables/ip6tables rules directly (this works
#     identically whether the running kernel backend is iptables-legacy or
#     the nft-based iptables-nft shim Ubuntu ships since 20.04 — we don't
#     need to hand-roll nftables syntax).
#
# All TUN devices created by this project are named `ovpnN` (N=0,1,2,...)
# specifically so firewall/NAT rules can match them with one wildcard
# (`ovpn+`) regardless of how many listeners are configured.

if [ -n "${_OVPN_FIREWALL_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_FIREWALL_LOADED=1

FW_STATE_DIR="${ETC_DIR}/firewall"
FW_UFW_RULES_FILE="${FW_STATE_DIR}/ufw-rules.list"
FW_IPT_RULES_FILE="${FW_STATE_DIR}/iptables-rules.list"
FW_UFW_MARK_BEGIN="# BEGIN OPENVPN-SERVER-MANAGER"
FW_UFW_MARK_END="# END OPENVPN-SERVER-MANAGER"
FW_TUN_PREFIX="ovpn"

fw_ufw_active() {
	command -v ufw >/dev/null 2>&1 || return 1
	ufw status 2>/dev/null | grep -qi "^Status: active"
}

fw_public_iface() { net_default_iface; }

# fw_ip6tables_usable: 0 only if ip6tables exists AND the kernel actually
# has IPv6 netfilter support loaded. Some minimal/container kernels ship
# the ip6tables binary without the matching netfilter modules, where every
# invocation fails at runtime — IPv6 firewalling must degrade gracefully
# there rather than aborting IPv4 setup (which always has to succeed).
_FW_IP6TABLES_USABLE=""
fw_ip6tables_usable() {
	if [ -z "$_FW_IP6TABLES_USABLE" ]; then
		if command -v ip6tables >/dev/null 2>&1 && ip6tables -L INPUT -n >/dev/null 2>&1; then
			_FW_IP6TABLES_USABLE=1
		else
			_FW_IP6TABLES_USABLE=0
		fi
	fi
	[ "$_FW_IP6TABLES_USABLE" = "1" ]
}

# _fw_track FILE LINE: append LINE to FILE only if not already present.
# fw_configure_from_state may call fw_allow_port/fw_apply_forward_and_nat
# repeatedly (settings changes, repair) against rules that already exist
# (the -C checks make the underlying add idempotent); without this the
# tracking files would grow a duplicate line per re-apply.
_fw_track() {
	local file="$1" line="$2"
	ensure_dir "$(dirname "$file")" 0700
	touch "$file"
	grep -qxF -- "$line" "$file" 2>/dev/null || echo "$line" >>"$file"
}

# --- port allow rules --------------------------------------------------
fw_allow_port() {
	local proto="$1" port="$2"
	ensure_dir "$FW_STATE_DIR" 0700
	if fw_ufw_active; then
		ufw allow "${port}/${proto}" comment "openvpn-server-manager" >/dev/null
		_fw_track "$FW_UFW_RULES_FILE" "${port}/${proto}"
	else
		iptables -C INPUT -p "$proto" --dport "$port" -m comment --comment "ovpn-mgr" -j ACCEPT 2>/dev/null || \
			iptables -A INPUT -p "$proto" --dport "$port" -m comment --comment "ovpn-mgr" -j ACCEPT
		_fw_track "$FW_IPT_RULES_FILE" "filter INPUT -p $proto --dport $port -m comment --comment ovpn-mgr -j ACCEPT"
		if fw_ip6tables_usable; then
			if ip6tables -C INPUT -p "$proto" --dport "$port" -m comment --comment "ovpn-mgr" -j ACCEPT 2>/dev/null || \
				ip6tables -A INPUT -p "$proto" --dport "$port" -m comment --comment "ovpn-mgr" -j ACCEPT 2>/dev/null; then
				_fw_track "$FW_IPT_RULES_FILE" "filter6 INPUT -p $proto --dport $port -m comment --comment ovpn-mgr -j ACCEPT"
			else
				log_warn "ip6tables rule for port ${port}/${proto} could not be added; continuing (IPv6 firewalling is best-effort)."
			fi
		fi
	fi
	return 0
}

# --- forwarding + NAT ----------------------------------------------------
fw_apply_forward_and_nat() {
	local pubif="$1"; shift
	local subnets=("$@")   # CIDRs, v4 and/or v6
	ensure_dir "$FW_STATE_DIR" 0700
	[ -n "$pubif" ] || { log_warn "Could not determine public interface; skipping NAT rule generation."; return 1; }

	if fw_ufw_active; then
		_fw_ufw_inject_before_rules "$pubif" "${subnets[@]}"
		ufw route allow in on "${FW_TUN_PREFIX}+" out on "$pubif" comment "openvpn-server-manager" >/dev/null 2>&1 || true
		ufw reload >/dev/null 2>&1 || true
	else
		# Forwarding between the VPN and the public interface.
		iptables -C FORWARD -i "${FW_TUN_PREFIX}+" -o "$pubif" -m comment --comment "ovpn-mgr" -j ACCEPT 2>/dev/null || \
			iptables -A FORWARD -i "${FW_TUN_PREFIX}+" -o "$pubif" -m comment --comment "ovpn-mgr" -j ACCEPT
		_fw_track "$FW_IPT_RULES_FILE" "filter FORWARD -i ${FW_TUN_PREFIX}+ -o $pubif -m comment --comment ovpn-mgr -j ACCEPT"

		iptables -C FORWARD -i "$pubif" -o "${FW_TUN_PREFIX}+" -m state --state RELATED,ESTABLISHED -m comment --comment "ovpn-mgr" -j ACCEPT 2>/dev/null || \
			iptables -A FORWARD -i "$pubif" -o "${FW_TUN_PREFIX}+" -m state --state RELATED,ESTABLISHED -m comment --comment "ovpn-mgr" -j ACCEPT
		_fw_track "$FW_IPT_RULES_FILE" "filter FORWARD -i $pubif -o ${FW_TUN_PREFIX}+ -m state --state RELATED,ESTABLISHED -m comment --comment ovpn-mgr -j ACCEPT"

		local s
		for s in "${subnets[@]}"; do
			[ -n "$s" ] || continue
			if [[ "$s" == *:* ]]; then
				fw_ip6tables_usable || continue
				if ip6tables -t nat -C POSTROUTING -s "$s" -o "$pubif" -m comment --comment "ovpn-mgr" -j MASQUERADE 2>/dev/null || \
					ip6tables -t nat -A POSTROUTING -s "$s" -o "$pubif" -m comment --comment "ovpn-mgr" -j MASQUERADE 2>/dev/null; then
					_fw_track "$FW_IPT_RULES_FILE" "nat6 POSTROUTING -s $s -o $pubif -m comment --comment ovpn-mgr -j MASQUERADE"
				else
					log_warn "ip6tables NAT rule for ${s} could not be added; continuing (IPv6 firewalling is best-effort)."
				fi
			else
				iptables -t nat -C POSTROUTING -s "$s" -o "$pubif" -m comment --comment "ovpn-mgr" -j MASQUERADE 2>/dev/null || \
					iptables -t nat -A POSTROUTING -s "$s" -o "$pubif" -m comment --comment "ovpn-mgr" -j MASQUERADE
				_fw_track "$FW_IPT_RULES_FILE" "nat POSTROUTING -s $s -o $pubif -m comment --comment ovpn-mgr -j MASQUERADE"
			fi
		done
	fi
	return 0
}

_fw_ufw_inject_before_rules() {
	local pubif="$1"; shift
	local subnets=("$@")
	local file="/etc/ufw/before.rules"
	[ -f "$file" ] || return 0
	_fw_ufw_strip_markers "$file"

	local frag
	frag="$(mktemp)"
	{
		echo "$FW_UFW_MARK_BEGIN"
		echo "*nat"
		echo ":POSTROUTING ACCEPT [0:0]"
		local s
		for s in "${subnets[@]}"; do
			[[ "$s" == *:* ]] && continue
			[ -n "$s" ] && echo "-A POSTROUTING -s $s -o $pubif -j MASQUERADE"
		done
		echo "COMMIT"
		echo "$FW_UFW_MARK_END"
	} >"$frag"

	# Insert our block right before the first *filter table (must precede it
	# for the nat table to be processed) while leaving everything else intact.
	awk -v inject="$frag" '
		!done && /^\*filter/ { while ((getline line < inject) > 0) print line; close(inject); done=1 }
		{ print }
	' "$file" >"${file}.new" && mv "${file}.new" "$file"
	rm -f "$frag"
}

_fw_ufw_strip_markers() {
	local file="$1"
	[ -f "$file" ] || return 0
	sed -i "/${FW_UFW_MARK_BEGIN}/,/${FW_UFW_MARK_END}/d" "$file"
}

# --- persistence across reboot (non-UFW path) ----------------------------
# UFW persists its own rules; for the raw iptables path we reapply our
# tracked rule list idempotently via a systemd oneshot unit at boot.
fw_apply_persisted() {
	[ -f "$FW_IPT_RULES_FILE" ] || return 0
	fw_ufw_active && return 0
	local table chain rest
	# shellcheck disable=SC2086 # $rest is an intentionally-unquoted multi-token rule spec
	while read -r table chain rest; do
		[ -n "$table" ] || continue
		case "$table" in
			filter) iptables -C "$chain" $rest 2>/dev/null || iptables -A "$chain" $rest || true ;;
			nat)    iptables -t nat -C "$chain" $rest 2>/dev/null || iptables -t nat -A "$chain" $rest || true ;;
			filter6) fw_ip6tables_usable && { ip6tables -C "$chain" $rest 2>/dev/null || ip6tables -A "$chain" $rest; }; true ;;
			nat6)    fw_ip6tables_usable && { ip6tables -t nat -C "$chain" $rest 2>/dev/null || ip6tables -t nat -A "$chain" $rest; }; true ;;
		esac
	done <"$FW_IPT_RULES_FILE"
	return 0
}

# --- full teardown (uninstall) -------------------------------------------
fw_remove_all() {
	if [ -f "$FW_UFW_RULES_FILE" ]; then
		local rule
		while read -r rule; do
			[ -n "$rule" ] && ufw delete allow "$rule" >/dev/null 2>&1 || true
		done <"$FW_UFW_RULES_FILE"
		rm -f "$FW_UFW_RULES_FILE"
	fi
	ufw route delete allow in on "${FW_TUN_PREFIX}+" out on "$(fw_public_iface)" >/dev/null 2>&1 || true
	_fw_ufw_strip_markers "/etc/ufw/before.rules"
	fw_ufw_active && ufw reload >/dev/null 2>&1 || true

	if [ -f "$FW_IPT_RULES_FILE" ]; then
		local table chain rest
		# shellcheck disable=SC2086 # $rest is an intentionally-unquoted multi-token rule spec
		while read -r table chain rest; do
			[ -n "$table" ] || continue
			case "$table" in
				filter) iptables -D "$chain" $rest 2>/dev/null || true ;;
				nat)    iptables -t nat -D "$chain" $rest 2>/dev/null || true ;;
				filter6) fw_ip6tables_usable && ip6tables -D "$chain" $rest 2>/dev/null; true ;;
				nat6)    fw_ip6tables_usable && ip6tables -t nat -D "$chain" $rest 2>/dev/null; true ;;
			esac
		done <"$FW_IPT_RULES_FILE"
		rm -f "$FW_IPT_RULES_FILE"
	fi
	rm -rf "$FW_STATE_DIR"
}

# fw_configure_from_state: (re)derive listener ports and per-listener
# subnets from the LISTENERS state and (re)apply port-allow + forward/NAT
# rules for all of them. Idempotent — safe to call on first install, after
# `ovpn settings` changes, and from `ovpn repair` to restore rules that
# were deleted out from under the manager (including the UFW case, where
# ordinary reboot-time persistence relies on UFW's own saved rule files and
# so doesn't help if a rule was manually removed rather than the system
# rebooted).
fw_configure_from_state() {
	local pubif; pubif="$(fw_public_iface)"
	[ -n "$pubif" ] || { log_warn "Could not determine public interface; skipping firewall configuration."; return 1; }

	local subnets=() idx=0 entry proto port family
	IFS=',' read -ra _fw_entries <<<"$(state_get LISTENERS "")"
	for entry in "${_fw_entries[@]}"; do
		[ -n "$entry" ] || continue
		IFS='|' read -r _ proto port _ family <<<"$entry"
		fw_allow_port "$proto" "$port"
		subnets+=("$(srvcfg_subnet_for_index "$idx" | awk '{print $1"/24"}')")
		[ "$family" = "6" ] && subnets+=("$(srvcfg_subnet6_for_index "$idx")")
		idx=$((idx + 1))
	done
	fw_apply_forward_and_nat "$pubif" "${subnets[@]}"
}

fw_summary() {
	if fw_ufw_active; then
		printf 'ufw (active)\n'
	elif command -v nft >/dev/null 2>&1 && nft list tables 2>/dev/null | grep -q .; then
		printf 'nftables (via iptables-nft)\n'
	elif command -v iptables >/dev/null 2>&1; then
		printf 'iptables\n'
	else
		printf 'none detected\n'
	fi
}
