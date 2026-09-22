#!/usr/bin/env bash
# repair.sh — non-destructive reconstruction of missing project-owned
# pieces. Never touches the PKI/CA beyond fixing permissions.

if [ -n "${_OVPN_REPAIR_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_REPAIR_LOADED=1

repair_run() {
	log_step "Repairing OpenVPN Server Manager installation"

	log_info "Ensuring runtime directories exist"
	ensure_dir "$OPT_DIR" 0755
	ensure_dir "$ETC_DIR" 0700
	ensure_dir "$VAR_DIR" 0700
	ensure_dir "${VAR_DIR}/clients" 0700
	ensure_dir "$LOG_DIR" 0750
	ensure_dir "$CLIENT_EXPORT_DIR" 0700
	ensure_dir "$SRV_CONF_DIR" 0755

	log_info "Fixing PKI permissions"
	if [ -d "$PKI_DIR" ]; then
		chmod 0700 "$PKI_DIR"
		[ -d "${PKI_DIR}/private" ] && chmod 0700 "${PKI_DIR}/private" && chmod 0600 "${PKI_DIR}"/private/*.key 2>/dev/null
		[ -f "${PKI_DIR}/crl.pem" ] && chmod 0644 "${PKI_DIR}/crl.pem"
	else
		log_warn "PKI directory missing at ${PKI_DIR} — not recreating automatically (would destroy client trust). Run 'ovpn diagnostics' for details."
	fi

	log_info "Ensuring 'ovpn' command is on PATH"
	if [ ! -e /usr/local/bin/ovpn ] || [ ! -x /usr/local/bin/ovpn ]; then
		ln -sf "${OPT_DIR}/bin/ovpn" /usr/local/bin/ovpn
		log_ok "Recreated /usr/local/bin/ovpn symlink."
	fi

	log_info "Reinstalling systemd unit templates"
	systemd_install_template "$(ovpn_engine_resolve_bin)" "$SRV_CONF_DIR"

	log_info "Syncing CRL"
	pki_sync_crl 2>/dev/null || true

	log_info "Regenerating server configs from saved state"
	if [ -n "$(state_get LISTENERS "")" ]; then
		srvcfg_generate_all
	else
		log_warn "No listener state found; nothing to regenerate. Run 'ovpn settings' to configure listeners."
	fi

	log_info "Re-applying firewall rules"
	if [ -n "$(state_get LISTENERS "")" ]; then
		fw_configure_from_state
		fw_apply_persisted
	fi

	log_info "Ensuring IP forwarding is enabled"
	local family; family="$(state_get IP_FAMILY ipv4)"
	net_enable_forwarding "$([ "$family" = "dual" ] && echo both || echo v4)"

	log_info "Reloading systemd and restarting listeners"
	systemctl daemon-reload
	systemd_restart_all

	log_ok "Repair complete. Run 'ovpn diagnostics' to verify."
}
