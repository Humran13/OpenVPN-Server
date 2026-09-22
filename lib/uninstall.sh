#!/usr/bin/env bash
# uninstall.sh — clean, project-scoped removal. Never touches anything
# this project did not create.

if [ -n "${_OVPN_UNINSTALL_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_UNINSTALL_LOADED=1

# uninstall_run MODE
#   MODE=keep-data    -- remove manager/services/firewall rules, keep PKI+config backup
#   MODE=full          -- remove everything including PKI and client exports
uninstall_run() {
	local mode="${1:-keep-data}"

	log_step "Stopping and disabling services"
	systemd_uninstall_template

	log_step "Removing tracked firewall rules"
	fw_remove_all

	log_step "Restoring IP forwarding sysctl state"
	net_restore_forwarding

	log_step "Removing apt repository (if we added it)"
	if [ -f /etc/apt/sources.list.d/openvpn-aptrepo.list ]; then
		rm -f /etc/apt/sources.list.d/openvpn-aptrepo.list /etc/apt/keyrings/openvpn-repo-public.asc
		log_info "Note: the 'openvpn' package itself was left installed (it is a normal system package, not project-owned)."
	fi

	log_step "Removing generated OpenVPN configs"
	rm -rf "$SRV_CONF_DIR"

	if [ "$mode" = "full" ]; then
		log_step "Removing PKI and manager state (irreversible)"
		rm -rf "$PKI_DIR" "$ETC_DIR" "$VAR_DIR"
		if confirm "Also delete exported client profiles in ${CLIENT_EXPORT_DIR}?"; then
			rm -rf "$CLIENT_EXPORT_DIR"
		fi
	else
		log_step "Preserving PKI and state (mode=keep-data)"
		local backup
		backup="$(backup_create "${VAR_DIR}/backups/pre-uninstall-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" 2>/dev/null)" || true
		if [ -n "$backup" ]; then
			log_info "Saved a full backup to: ${backup}"
		fi
		log_info "PKI left at ${PKI_DIR}; manager state left at ${ETC_DIR}."
	fi

	log_step "Removing manager files"
	rm -f /usr/local/bin/ovpn
	rm -rf "${OPT_DIR}"

	log_ok "Uninstall complete."
	if [ "$mode" != "full" ]; then
		log_info "Re-run the installer at any time to reinstall the manager against the preserved PKI/state."
	fi
	return 0
}
