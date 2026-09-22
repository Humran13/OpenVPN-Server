#!/usr/bin/env bash
# backup.sh / restore.sh — project backup and restore.
#
# Archive layout (relative paths, no leading '/', no '..'):
#   pki/                  -- full Easy-RSA PKI (CA, issued certs, keys, CRL)
#   state.conf            -- manager state
#   manager.conf           -- manager config overrides (if any)
#   server-manager/        -- generated OpenVPN server configs (regenerable,
#                              included for convenience/speed of restore)
#   firewall/               -- tracked firewall rule lists
#   MANIFEST                -- manager version + timestamp + sha256 of PKI tree

if [ -n "${_OVPN_BACKUP_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_BACKUP_LOADED=1

BACKUP_DEFAULT_DIR="${VAR_DIR}/backups"

backup_create() {
	local outfile="${1:-}"
	[ -n "$outfile" ] || outfile="${BACKUP_DEFAULT_DIR}/ovpn-backup-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
	ensure_dir "$(dirname "$outfile")" 0700

	local stage; stage="$(mktemp -d)"
	chmod 0700 "$stage"
	trap 'rm -rf "$stage"' RETURN

	[ -d "$PKI_DIR" ] && cp -a "$PKI_DIR" "$stage/pki"
	[ -f "$STATE_FILE" ] && cp -a "$STATE_FILE" "$stage/state.conf"
	[ -f "${ETC_DIR}/manager.conf" ] && cp -a "${ETC_DIR}/manager.conf" "$stage/manager.conf"
	[ -d "$SRV_CONF_DIR" ] && cp -a "$SRV_CONF_DIR" "$stage/server-manager"
	[ -d "$FW_STATE_DIR" ] && cp -a "$FW_STATE_DIR" "$stage/firewall"

	{
		echo "manager_version=${MANAGER_VERSION}"
		echo "created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "pki_sha256=$(find "$stage/pki" -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | awk '{print $1}')"
	} >"$stage/MANIFEST"

	( umask 077; tar -czf "$outfile" -C "$stage" . ) || die "Failed to create backup archive."
	chmod 0600 "$outfile"
	rm -rf "$stage"
	trap - RETURN
	log_ok "Backup created: ${outfile}"
	printf '%s\n' "$outfile"
}

# backup_validate archive: reject anything unsafe before extraction.
backup_validate() {
	local archive="$1"
	[ -f "$archive" ] || { log_error "Backup file not found: $archive"; return 1; }
	local listing
	listing="$(tar -tzf "$archive" 2>/dev/null)" || { log_error "Not a valid gzip tar archive."; return 1; }
	[ -n "$listing" ] || { log_error "Backup archive is empty."; return 1; }
	if printf '%s\n' "$listing" | grep -qE '(^|/)\.\.(/|$)|^/'; then
		log_error "Backup archive contains unsafe paths (path traversal). Refusing to restore."
		return 1
	fi
	printf '%s\n' "$listing" | grep -qE '^(\./)?MANIFEST$' || { log_error "Backup archive missing MANIFEST; refusing to restore."; return 1; }
	printf '%s\n' "$listing" | grep -qE '^(\./)?pki/' || { log_error "Backup archive missing pki/; refusing to restore."; return 1; }
	return 0
}

restore_from() {
	local archive="$1"
	backup_validate "$archive" || die "Backup validation failed."

	log_step "Backing up current state before restore (safety net)"
	local pre_restore
	pre_restore="$(backup_create "${BACKUP_DEFAULT_DIR}/pre-restore-$(date -u +%Y%m%dT%H%M%SZ).tar.gz")"

	local stage; stage="$(mktemp -d)"
	chmod 0700 "$stage"
	tar -xzf "$archive" -C "$stage" || die "Failed to extract backup archive."

	log_step "Restoring PKI and configuration"
	[ -d "$stage/pki" ] || die "Restore aborted: archive has no pki/ directory."
	rm -rf "${PKI_DIR}.restoring"
	cp -a "$stage/pki" "${PKI_DIR}.restoring"

	local prev_pki="${PKI_DIR}.pre-restore-$$"
	[ -d "$PKI_DIR" ] && mv "$PKI_DIR" "$prev_pki"
	mv "${PKI_DIR}.restoring" "$PKI_DIR"

	[ -f "$stage/state.conf" ] && install -m 0600 "$stage/state.conf" "$STATE_FILE"
	[ -f "$stage/manager.conf" ] && install -m 0600 "$stage/manager.conf" "${ETC_DIR}/manager.conf"
	[ -d "$stage/server-manager" ] && { rm -rf "$SRV_CONF_DIR"; cp -a "$stage/server-manager" "$SRV_CONF_DIR"; }
	[ -d "$stage/firewall" ] && { rm -rf "$FW_STATE_DIR"; cp -a "$stage/firewall" "$FW_STATE_DIR"; }

	pki_sync_crl
	srvcfg_generate_all
	systemd_restart_all

	log_step "Verifying restored service"
	sleep 2
	local ok=1 entry name
	IFS=',' read -ra _entries <<<"$(state_get LISTENERS "")"
	for entry in "${_entries[@]}"; do
		[ -n "$entry" ] || continue
		IFS='|' read -r name _ _ _ _ <<<"$entry"
		[ "$(systemd_status_instance "$name")" = "active" ] || ok=0
	done

	if [ "$ok" -eq 1 ]; then
		log_ok "Restore verified: all listeners active."
		rm -rf "$prev_pki" "$stage"
		return 0
	fi

	log_error "Restore verification FAILED. Rolling back to pre-restore state."
	rm -rf "$PKI_DIR"
	[ -d "$prev_pki" ] && mv "$prev_pki" "$PKI_DIR"
	pki_sync_crl
	srvcfg_generate_all
	systemd_restart_all
	rm -rf "$stage"
	die "Restore failed and was rolled back. A pre-restore safety backup is available at: ${pre_restore}"
}
