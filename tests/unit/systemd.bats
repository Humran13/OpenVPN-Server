#!/usr/bin/env bats
# Unit tests for lib/systemd.sh — generated unit content and listener
# lifecycle sync. Regression coverage for a real production bug: OpenVPN
# listeners on privileged ports (e.g. TCP 443) failed to start under
# systemd because CapabilityBoundingSet omitted CAP_NET_BIND_SERVICE.

setup() {
	ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
	ETC_DIR="$(mktemp -d)"
	SYSTEMD_UNIT_DIR="$(mktemp -d)"
	SRV_CONF_DIR="$(mktemp -d)"
	STATE_FILE="${ETC_DIR}/state.conf"
	OPT_DIR="$(mktemp -d)"
	source "${ROOT_DIR}/lib/common.sh"
	source "${ROOT_DIR}/lib/state.sh"
	source "${ROOT_DIR}/lib/systemd.sh"
	SYSTEMD_UNIT_DIR="$(mktemp -d)" # re-pin: systemd.sh sets a default on load

	SYSTEMCTL_LOG="$(mktemp)"
	systemctl() { printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"; return 0; }
	export -f systemctl
}

teardown() {
	rm -rf "$ETC_DIR" "$SYSTEMD_UNIT_DIR" "$SRV_CONF_DIR" "$OPT_DIR" "${SYSTEMCTL_LOG:-}"
}

# --- generated unit content -------------------------------------------------
@test "generated service unit grants CAP_NET_BIND_SERVICE" {
	systemd_install_template "/usr/local/sbin/openvpn" "$SRV_CONF_DIR"
	unit="${SYSTEMD_UNIT_DIR}/${SVC_TEMPLATE}.service"
	[ -f "$unit" ]
	grep -q "^CapabilityBoundingSet=.*CAP_NET_BIND_SERVICE" "$unit"
}

@test "generated service unit still has every previously-required capability" {
	systemd_install_template "/usr/local/sbin/openvpn" "$SRV_CONF_DIR"
	unit="${SYSTEMD_UNIT_DIR}/${SVC_TEMPLATE}.service"
	line="$(grep "^CapabilityBoundingSet=" "$unit")"
	for cap in CAP_NET_ADMIN CAP_NET_RAW CAP_SETGID CAP_SETUID CAP_DAC_OVERRIDE CAP_CHOWN CAP_NET_BIND_SERVICE; do
		[[ "$line" == *"$cap"* ]] || { echo "missing $cap in: $line"; return 1; }
	done
}

@test "generated unit's ConditionPathExists/ExecStart resolve correctly for a real privileged-port instance (tcp443)" {
	systemd_install_template "/usr/local/sbin/openvpn" "$SRV_CONF_DIR"
	: >"${SRV_CONF_DIR}/tcp443.conf"
	unit="${SYSTEMD_UNIT_DIR}/${SVC_TEMPLATE}.service"
	cond="$(grep '^ConditionPathExists=' "$unit" | cut -d= -f2-)"
	instantiated="${cond/\%i/tcp443}"
	[ -f "$instantiated" ]
	exec_line="$(grep '^ExecStart=' "$unit")"
	[[ "$exec_line" == *"${SRV_CONF_DIR}/%i.conf"* ]]
}

# --- stale listener cleanup --------------------------------------------------
@test "systemd_sync_listeners removes a listener dropped from the new configuration" {
	: >"${SRV_CONF_DIR}/tcp443.conf"
	: >"${SRV_CONF_DIR}/udp1194.conf"
	old="udp1194|udp|1194|ovpn0|4,tcp443|tcp|443|ovpn1|4"
	new="udp1194|udp|1194|ovpn0|4"
	systemd_sync_listeners "$old" "$new"
	grep -q "disable --now ${SVC_TEMPLATE}tcp443.service" "$SYSTEMCTL_LOG"
	[ ! -f "${SRV_CONF_DIR}/tcp443.conf" ]
	# the kept listener must be untouched
	! grep -q "udp1194" "$SYSTEMCTL_LOG"
	[ -f "${SRV_CONF_DIR}/udp1194.conf" ]
}

@test "systemd_sync_listeners does nothing when old and new listeners are identical" {
	: >"${SRV_CONF_DIR}/udp1194.conf"
	same="udp1194|udp|1194|ovpn0|4"
	systemd_sync_listeners "$same" "$same"
	[ ! -s "$SYSTEMCTL_LOG" ]
	[ -f "${SRV_CONF_DIR}/udp1194.conf" ]
}

@test "systemd_sync_listeners handles an empty new configuration by removing all old listeners" {
	: >"${SRV_CONF_DIR}/tcp443.conf"
	systemd_sync_listeners "tcp443|tcp|443|ovpn0|4" ""
	grep -q "disable --now ${SVC_TEMPLATE}tcp443.service" "$SYSTEMCTL_LOG"
	[ ! -f "${SRV_CONF_DIR}/tcp443.conf" ]
}
