#!/usr/bin/env bash
# update.sh — two independent update paths: the manager (this project) and
# the OpenVPN engine (upstream). Never conflated; see project scope notes.

if [ -n "${_OVPN_UPDATE_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_UPDATE_LOADED=1

# --- manager self-update ---------------------------------------------------
update_manager_check() {
	curl -fsSL --max-time 10 "https://api.github.com/repos/${MANAGER_GITHUB_REPO}/releases/latest" 2>/dev/null \
		| grep -m1 '"tag_name"' | sed -E 's/.*"v?([0-9.]+)".*/\1/'
}

update_manager() {
	log_step "Checking for OpenVPN Server Manager updates"
	local latest
	latest="$(update_manager_check)"
	if [ -z "$latest" ]; then
		log_warn "Could not reach GitHub to check for updates."
		return 1
	fi
	if [ "$latest" = "$MANAGER_VERSION" ]; then
		log_ok "Already up to date (v${MANAGER_VERSION})."
		return 0
	fi
	log_info "Update available: v${MANAGER_VERSION} -> v${latest}"
	confirm "Download and install v${latest}?" || { log_info "Update cancelled."; return 0; }

	local tmp; tmp="$(mktemp -d)"
	local tarball="https://github.com/${MANAGER_GITHUB_REPO}/archive/refs/tags/v${latest}.tar.gz"
	curl -fsSL --max-time 60 -o "${tmp}/manager.tar.gz" "$tarball" || { log_error "Download failed."; rm -rf "$tmp"; return 1; }
	tar -xzf "${tmp}/manager.tar.gz" -C "$tmp" || { log_error "Extraction failed."; rm -rf "$tmp"; return 1; }
	local src; src="$(find "$tmp" -maxdepth 1 -type d -name 'OpenVPN-Server-*' | head -n1)"
	[ -n "$src" ] || { log_error "Unexpected archive layout."; rm -rf "$tmp"; return 1; }

	log_info "Validating downloaded release"
	local f bad=0
	while IFS= read -r -d '' f; do
		bash -n "$f" || bad=1
	done < <(find "$src" -name '*.sh' -print0)
	[ -x "$src/bin/ovpn" ] || bad=1
	if [ "$bad" -ne 0 ]; then
		log_error "Downloaded release failed validation; aborting update."
		rm -rf "$tmp"
		return 1
	fi

	local backup="${OPT_DIR}.pre-update-$$"
	cp -a "$OPT_DIR" "$backup"
	if cp -a "$src/." "$OPT_DIR/" && chmod +x "${OPT_DIR}/bin/ovpn"; then
		state_set MANAGER_VERSION "$latest"
		log_ok "Manager updated to v${latest}. Backup of previous version kept at ${backup}"
		rm -rf "$tmp"
		return 0
	fi

	log_error "Update failed; rolling back."
	rm -rf "$OPT_DIR"
	mv "$backup" "$OPT_DIR"
	rm -rf "$tmp"
	return 1
}

# --- OpenVPN engine update ---------------------------------------------------
update_engine() {
	log_step "Updating OpenVPN engine"
	local method; method="$(state_get OPENVPN_INSTALL_METHOD apt)"
	local before_ver; before_ver="$(ovpn_engine_installed_version "$(ovpn_engine_resolve_bin)")"

	if [ "$method" = "apt" ]; then
		local before_pkg
		before_pkg="$(dpkg-query -W -f='${Version}' openvpn 2>/dev/null)"
		run_quiet apt-get update || true
		if ! run_quiet apt-get install --only-upgrade -y openvpn; then
			log_error "apt upgrade failed."
			return 1
		fi
	else
		cp -a "$OPENVPN_BUILD_BIN" "${OPENVPN_BUILD_BIN}.previous" 2>/dev/null || true
		if ! _ovpn_install_via_source; then
			log_error "Source rebuild failed."
			return 1
		fi
	fi

	local after_ver; after_ver="$(ovpn_engine_installed_version "$(ovpn_engine_resolve_bin)")"
	log_info "OpenVPN ${before_ver:-?} -> ${after_ver:-?}"

	log_info "Validating configs against the new engine before restarting"
	local entry name ok=1
	IFS=',' read -ra _entries <<<"$(state_get LISTENERS "")"
	for entry in "${_entries[@]}"; do
		[ -n "$entry" ] || continue
		IFS='|' read -r name _ _ _ _ <<<"$entry"
		srvcfg_validate "$name" || ok=0
	done

	if [ "$ok" -ne 1 ]; then
		log_error "New engine failed config validation. Rolling back."
		if [ "$method" = "apt" ] && [ -n "$before_pkg" ]; then
			run_quiet apt-get install --allow-downgrades -y "openvpn=${before_pkg}" || log_error "Automatic downgrade failed; manual intervention required."
		elif [ -f "${OPENVPN_BUILD_BIN}.previous" ]; then
			mv "${OPENVPN_BUILD_BIN}.previous" "$OPENVPN_BUILD_BIN"
		fi
		return 1
	fi

	systemctl daemon-reload
	systemd_restart_all
	sleep 2
	ok=1
	for entry in "${_entries[@]}"; do
		[ -n "$entry" ] || continue
		IFS='|' read -r name _ _ _ _ <<<"$entry"
		[ "$(systemd_status_instance "$name")" = "active" ] || ok=0
	done
	if [ "$ok" -ne 1 ]; then
		log_error "Listeners failed to come up after engine update. Check 'ovpn logs' and consider 'ovpn restore'."
		return 1
	fi
	rm -f "${OPENVPN_BUILD_BIN}.previous"
	log_ok "OpenVPN engine updated and verified: ${after_ver}"
}
