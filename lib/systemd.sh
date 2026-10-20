#!/usr/bin/env bash
# systemd.sh — manages our own systemd unit templates. We never touch or
# rely on any systemd unit shipped by the openvpn distro package; every
# unit here is uniquely named "openvpn-server-manager*" so it cannot
# collide with anything else on the system.

if [ -n "${_OVPN_SYSTEMD_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_SYSTEMD_LOADED=1

SYSTEMD_UNIT_DIR="/etc/systemd/system"
SVC_TEMPLATE="openvpn-server-manager@"
SVC_FIREWALL="openvpn-server-manager-firewall"

systemd_install_template() {
	local openvpn_bin="$1"   # resolved absolute path to the openvpn binary to run
	local confdir="$2"       # directory containing <instance>.conf files

	cat >"${SYSTEMD_UNIT_DIR}/${SVC_TEMPLATE}.service" <<EOF
[Unit]
Description=OpenVPN Server Manager - listener %i
Documentation=https://github.com/${MANAGER_GITHUB_REPO:-Humran13/OpenVPN-Server}
After=network-online.target
Wants=network-online.target
ConditionPathExists=${confdir}/%i.conf

[Service]
Type=notify
PrivateTmp=true
ExecStart=${openvpn_bin} --config ${confdir}/%i.conf
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_SETGID CAP_SETUID CAP_DAC_OVERRIDE CAP_CHOWN CAP_NET_BIND_SERVICE
LimitNPROC=100
DeviceAllow=/dev/net/tun
ProtectSystem=full
Restart=on-failure
RestartSec=3
RuntimeDirectory=openvpn-server-manager-%i

[Install]
WantedBy=multi-user.target
EOF

	cat >"${SYSTEMD_UNIT_DIR}/${SVC_FIREWALL}.service" <<EOF
[Unit]
Description=OpenVPN Server Manager - reapply tracked firewall rules at boot
Documentation=https://github.com/${MANAGER_GITHUB_REPO:-Humran13/OpenVPN-Server}
After=network-pre.target
Before=network-online.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=${OPT_DIR}/bin/ovpn --internal-fw-persist
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable "${SVC_FIREWALL}.service" >/dev/null 2>&1 || true
}

systemd_uninstall_template() {
	local inst
	for inst in $(systemd_list_instances); do
		systemctl disable --now "${SVC_TEMPLATE}${inst}.service" >/dev/null 2>&1 || true
	done
	systemctl disable --now "${SVC_FIREWALL}.service" >/dev/null 2>&1 || true
	rm -f "${SYSTEMD_UNIT_DIR}/${SVC_TEMPLATE}.service" "${SYSTEMD_UNIT_DIR}/${SVC_FIREWALL}.service"
	systemctl daemon-reload
}

systemd_enable_instance() { systemctl enable --now "${SVC_TEMPLATE}$1.service"; }
systemd_disable_instance() { systemctl disable --now "${SVC_TEMPLATE}$1.service" >/dev/null 2>&1 || true; }
systemd_restart_instance() { systemctl restart "${SVC_TEMPLATE}$1.service"; }
systemd_status_instance() { systemctl is-active "${SVC_TEMPLATE}$1.service" 2>/dev/null || echo "inactive"; }

systemd_list_instances() {
	state_get "LISTENERS" "" | tr ',' '\n' | awk -F'|' 'NF{print $1}'
}

systemd_restart_all() {
	local inst
	for inst in $(systemd_list_instances); do
		systemctl restart "${SVC_TEMPLATE}${inst}.service" || log_warn "Failed to restart listener '${inst}'"
	done
}

# systemd_sync_listeners old_listeners_csv new_listeners_csv — stops,
# disables and removes the generated config of every listener instance
# present in the OLD state's LISTENERS encoding but absent from the NEW
# one, so a settings change never leaves a stale, still-enabled listener
# behind. Listeners present in both (even on a different port) are left
# alone here; srvcfg_generate_all/systemd_restart_all handle picking up
# their new config.
systemd_sync_listeners() {
	local old_csv="$1" new_csv="$2" old_names new_names name keep other
	old_names="$(printf '%s' "$old_csv" | tr ',' '\n' | awk -F'|' 'NF{print $1}')"
	new_names="$(printf '%s' "$new_csv" | tr ',' '\n' | awk -F'|' 'NF{print $1}')"
	for name in $old_names; do
		keep=0
		for other in $new_names; do
			[ "$other" = "$name" ] && { keep=1; break; }
		done
		if [ "$keep" -eq 0 ]; then
			log_info "Removing stale listener '${name}' (no longer in configuration)"
			systemd_disable_instance "$name"
			rm -f "${SRV_CONF_DIR}/${name}.conf"
		fi
	done
}
