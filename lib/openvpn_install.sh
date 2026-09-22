#!/usr/bin/env bash
# openvpn_install.sh — installs the OpenVPN Community Edition engine using
# the strategy documented in config/upstream.conf:
#   1. If the official OpenVPN apt repo has a current 2.7.x build for this
#      Ubuntu codename, use it (signed, official, easiest to keep updated).
#   2. Otherwise, build the pinned stable release from verified upstream
#      source (checksum + GPG signature against the official release key).
# Distro `apt install openvpn` is deliberately NOT used as the default path
# because it frequently ships years-old versions (see upstream.conf notes).

if [ -n "${_OVPN_INSTALL_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_INSTALL_LOADED=1

OPENVPN_BUILD_PREFIX="/usr/local"
OPENVPN_BUILD_BIN="${OPENVPN_BUILD_PREFIX}/sbin/openvpn"

ovpn_engine_apt_available() {
	local codename="$1" cn
	for cn in ${OPENVPN_APT_SUPPORTED_CODENAMES:-}; do
		[ "$cn" = "$codename" ] && return 0
	done
	return 1
}

ovpn_engine_installed_version() {
	local bin="$1"
	[ -x "$bin" ] || return 1
	"$bin" --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

ovpn_engine_resolve_bin() {
	if [ -x "$OPENVPN_BUILD_BIN" ]; then
		printf '%s\n' "$OPENVPN_BUILD_BIN"
	elif command -v openvpn >/dev/null 2>&1; then
		command -v openvpn
	else
		printf '/usr/sbin/openvpn\n'
	fi
}

# --- strategy 1: official apt repo ---------------------------------------
_ovpn_install_via_apt_repo() {
	local codename="$1" arch="$2"
	log_step "Installing OpenVPN ${OPENVPN_VERSION} from the official OpenVPN apt repository"

	ensure_dir /etc/apt/keyrings 0755
	if ! curl -fsSL --max-time 15 "$OPENVPN_APT_KEY_URL" -o /etc/apt/keyrings/openvpn-repo-public.asc; then
		log_warn "Could not fetch official OpenVPN apt signing key; falling back to source build."
		return 1
	fi

	# Verify the key fingerprint by importing into a scratch keyring rather
	# than `gpg --show-keys` (not available on older GnuPG, e.g. 2.2.4 on
	# Ubuntu 18.04) — this works identically across all GnuPG versions.
	local fpr fpr_home
	fpr_home="$(mktemp -d)"
	chmod 700 "$fpr_home"
	GNUPGHOME="$fpr_home" gpg --batch --import /etc/apt/keyrings/openvpn-repo-public.asc >/dev/null 2>&1
	fpr="$(GNUPGHOME="$fpr_home" gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
	rm -rf "$fpr_home"
	if [ "$fpr" != "$OPENVPN_APT_KEY_FINGERPRINT" ]; then
		log_warn "OpenVPN apt repo key fingerprint mismatch (got '$fpr', expected '$OPENVPN_APT_KEY_FINGERPRINT'). Falling back to source build."
		rm -f /etc/apt/keyrings/openvpn-repo-public.asc
		return 1
	fi

	cat >/etc/apt/sources.list.d/openvpn-aptrepo.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/openvpn-repo-public.asc] ${OPENVPN_APT_REPO_BASE} ${codename} main
EOF

	if ! run_quiet apt-get update -o Dir::Etc::sourcelist="sources.list.d/openvpn-aptrepo.list" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"; then
		run_quiet apt-get update || true
	fi

	if ! run_quiet apt-get install -y --no-install-recommends openvpn; then
		log_warn "apt install of openvpn from the official repo failed; falling back to source build."
		rm -f /etc/apt/sources.list.d/openvpn-aptrepo.list
		return 1
	fi

	local installed
	installed="$(ovpn_engine_installed_version /usr/sbin/openvpn)"
	if [ "$installed" != "$OPENVPN_VERSION" ]; then
		log_warn "Installed OpenVPN version ($installed) differs from pinned ($OPENVPN_VERSION); continuing anyway (repo may have moved on)."
	fi
	log_ok "OpenVPN ${installed:-$OPENVPN_VERSION} installed via official apt repository."
	# shellcheck disable=SC2034 # consumed by install.sh/repair.sh after sourcing this file
	OPENVPN_INSTALL_METHOD="apt"
	OPENVPN_INSTALL_BIN="/usr/sbin/openvpn"
	return 0
}

# --- strategy 2: verified source build ------------------------------------
_ovpn_install_build_deps() {
	log_step "Installing build dependencies for OpenVPN ${OPENVPN_VERSION}"
	run_quiet apt-get update
	run_quiet apt-get install -y --no-install-recommends \
		build-essential pkg-config libssl-dev liblzo2-dev liblz4-dev \
		libpam0g-dev libcap-ng-dev libnl-genl-3-dev linux-libc-dev libsystemd-dev \
		libpkcs11-helper1-dev \
		ca-certificates gnupg curl wget || die "Failed to install OpenVPN build dependencies."
}

_ovpn_install_via_source() {
	log_step "Building OpenVPN ${OPENVPN_VERSION} from verified upstream source"
	_ovpn_install_build_deps

	local workdir
	workdir="$(mktemp -d /tmp/ovpn-build.XXXXXX)"
	trap 'rm -rf "$workdir"' RETURN

	( umask 022
	  cd "$workdir"
	  log_info "Downloading openvpn-${OPENVPN_VERSION}.tar.gz"
	  curl -fsSL --max-time 60 -o openvpn.tar.gz "$OPENVPN_SOURCE_URL" || die "Download of OpenVPN source failed."
	  curl -fsSL --max-time 30 -o openvpn.tar.gz.asc "$OPENVPN_SOURCE_SIG_URL" || die "Download of OpenVPN source signature failed."

	  log_info "Verifying checksum"
	  local sum
	  sum="$(sha256sum openvpn.tar.gz | awk '{print $1}')"
	  [ "$sum" = "$OPENVPN_SOURCE_SHA256" ] || die "OpenVPN source checksum mismatch! Expected $OPENVPN_SOURCE_SHA256, got $sum. Aborting (possible tampering)."

	  log_info "Verifying GPG signature against pinned key ${OPENVPN_GPG_FINGERPRINT}"
	  export GNUPGHOME="$workdir/.gnupg"
	  mkdir -m 700 "$GNUPGHOME"
	  curl -fsSL --max-time 15 "$OPENVPN_GPG_KEY_URL" -o key.asc || die "Failed to fetch OpenVPN release signing key."
	  gpg --batch --import key.asc >/dev/null 2>&1 || die "Failed to import OpenVPN release signing key."
	  local imported_fpr
	  imported_fpr="$(gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
	  [ "$imported_fpr" = "$OPENVPN_GPG_FINGERPRINT" ] || die "OpenVPN signing key fingerprint mismatch (got $imported_fpr)."
	  gpg --batch --status-fd 1 --verify openvpn.tar.gz.asc openvpn.tar.gz 2>/dev/null | grep -q "^\[GNUPG:\] GOODSIG" || \
		  die "OpenVPN source signature verification FAILED. Refusing to build unverified code."
	  log_ok "Signature verified: OpenVPN ${OPENVPN_VERSION} source is authentic."

	  tar xzf openvpn.tar.gz
	  cd "openvpn-${OPENVPN_VERSION}"
	  log_info "Configuring build (prefix=${OPENVPN_BUILD_PREFIX})"
	  if ! ./configure --prefix="$OPENVPN_BUILD_PREFIX" --enable-pkcs11 --enable-systemd \
		  >"$workdir/configure.log" 2>&1; then
		  if grep -qi "DCO" "$workdir/configure.log"; then
			  log_warn "Data Channel Offload (DCO) build prerequisites are not met on this system (libnl-genl too old); retrying without DCO. OpenVPN will still work correctly, just without kernel-offload."
			  ./configure --prefix="$OPENVPN_BUILD_PREFIX" --enable-pkcs11 --enable-systemd --disable-dco \
				  >"$workdir/configure.log" 2>&1 || { tail -n 60 "$workdir/configure.log" >&2; die "OpenVPN ./configure failed even without DCO (see above)."; }
		  else
			  tail -n 60 "$workdir/configure.log" >&2
			  die "OpenVPN ./configure failed (see above)."
		  fi
	  fi
	  log_info "Compiling (this can take a few minutes)"
	  if ! make -j"$(nproc)" >"$workdir/make.log" 2>&1; then
		  if grep -q "SSL_get_peer_tmp_key" "$workdir/make.log"; then
			  die "OpenVPN ${OPENVPN_VERSION} requires OpenSSL >= 1.1.1a (SSL_get_peer_tmp_key), but this system's OpenSSL library predates that (Ubuntu 18.04's system OpenSSL package stays pinned to the original 1.1.1 base and only backports CVE fixes, never new API surface). Building OpenVPN 2.7.x from source is not possible against this system's OpenSSL without either patching upstream OpenVPN or replacing the system OpenSSL package — both out of scope for this installer. Please use Ubuntu 20.04 or newer for a source-built install, or a distro where the official OpenVPN apt repository already carries 2.7.x."
		  fi
		  tail -n 60 "$workdir/make.log" >&2
		  die "OpenVPN build failed (see above)."
	  fi
	  log_info "Installing to ${OPENVPN_BUILD_PREFIX}"
	  make install >"$workdir/install.log" 2>&1 || { tail -n 60 "$workdir/install.log" >&2; die "OpenVPN install failed (see above)."; }
	) || die "OpenVPN source build failed."

	rm -rf "$workdir"
	trap - RETURN

	[ -x "$OPENVPN_BUILD_BIN" ] || die "OpenVPN build reported success but binary not found at $OPENVPN_BUILD_BIN"
	local installed
	installed="$("$OPENVPN_BUILD_BIN" --version 2>/dev/null | head -n1)"
	log_ok "Built and installed: $installed"
	# shellcheck disable=SC2034 # both consumed by install.sh/repair.sh after sourcing this file
	OPENVPN_INSTALL_METHOD="source"
	# shellcheck disable=SC2034
	OPENVPN_INSTALL_BIN="$OPENVPN_BUILD_BIN"
}

# Codenames where a verified source build of the pinned OpenVPN release is
# known NOT to be achievable: their system OpenSSL predates OpenSSL 1.1.1a
# (SSL_get_peer_tmp_key, required since OpenVPN 2.7.x), and Ubuntu never
# backports new OpenSSL API surface into an LTS's system package — only CVE
# fixes. Fixing this would require either patching upstream OpenVPN source
# or replacing the system OpenSSL package, both out of scope (no upstream
# patches, no broad system changes). Verified empirically on bionic.
OPENVPN_SOURCE_BUILD_BLOCKED_CODENAMES="bionic"

# ovpn_engine_install: entry point. Sets OPENVPN_INSTALL_METHOD and
# OPENVPN_INSTALL_BIN as side effects.
ovpn_engine_install() {
	local codename="$1" arch="$2" cn

	if ovpn_engine_apt_available "$codename"; then
		if _ovpn_install_via_apt_repo "$codename" "$arch"; then
			return 0
		fi
		log_warn "Official apt repo path failed for ${codename}; falling back to verified source build."
	else
		log_info "Official OpenVPN apt repo does not carry current 2.7.x for '${codename}'; using a verified source build instead."
	fi

	for cn in $OPENVPN_SOURCE_BUILD_BLOCKED_CODENAMES; do
		if [ "$cn" = "$codename" ]; then
			log_warn "OpenVPN ${OPENVPN_VERSION} cannot be built from source on '${codename}': its system OpenSSL predates OpenSSL 1.1.1a, which OpenVPN 2.7.x requires (SSL_get_peer_tmp_key). This is a known, verified limitation of this EOL release, not a transient failure."
			log_warn "Falling back to the newest OFFICIAL OpenVPN package available for '${codename}' (an older but still officially-maintained 2.x release) so this host still ends up with a working, authentic OpenVPN install."
			if _ovpn_install_via_apt_repo "$codename" "$arch"; then
				return 0
			fi
			die "No working OpenVPN install strategy succeeded for '${codename}'. Please upgrade to a currently supported Ubuntu LTS release."
		fi
	done

	_ovpn_install_via_source
}

ovpn_engine_test_binary() {
	local bin="$1"
	"$bin" --version >/dev/null 2>&1 || die "Installed OpenVPN binary failed to run: $bin --version"
	log_ok "Verified OpenVPN binary runs: $bin"
}

# ovpn_engine_dco_available: 0 if the ovpn-dco kernel module is present/loadable.
ovpn_engine_dco_available() {
	lsmod 2>/dev/null | grep -q '^ovpn_dco' && return 0
	modprobe ovpn-dco >/dev/null 2>&1 && { rmmod ovpn-dco >/dev/null 2>&1 || true; return 0; }
	return 1
}
