#!/usr/bin/env bash
# pki.sh — Easy-RSA based PKI: CA, server cert, per-client certs, CRL,
# revocation and renewal. Wraps the pinned, checksum+signature verified
# Easy-RSA release (see config/upstream.conf).

if [ -n "${_OVPN_PKI_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_PKI_LOADED=1

EASYRSA_INSTALL_DIR="${OPT_DIR}/easyrsa"
EASYRSA_BIN="${EASYRSA_INSTALL_DIR}/easyrsa"

pki_install_easyrsa() {
	[ -x "$EASYRSA_BIN" ] && return 0
	log_step "Installing Easy-RSA ${EASYRSA_VERSION} (verified)"

	local workdir
	workdir="$(mktemp -d /tmp/easyrsa-build.XXXXXX)"
	( umask 022
	  cd "$workdir"
	  curl -fsSL --max-time 30 -o easyrsa.tgz "$EASYRSA_SOURCE_URL" || die "Download of Easy-RSA source failed."
	  curl -fsSL --max-time 20 -o easyrsa.tgz.sig "$EASYRSA_SOURCE_SIG_URL" || die "Download of Easy-RSA signature failed."

	  local sum
	  sum="$(sha256sum easyrsa.tgz | awk '{print $1}')"
	  [ "$sum" = "$EASYRSA_SOURCE_SHA256" ] || die "Easy-RSA checksum mismatch! Expected $EASYRSA_SOURCE_SHA256, got $sum. Aborting."

	  export GNUPGHOME="$workdir/.gnupg"
	  mkdir -m 700 "$GNUPGHOME"
	  curl -fsSL --max-time 15 "$EASYRSA_GPG_KEY_URL" -o key.asc || die "Failed to fetch Easy-RSA release signing key."
	  gpg --batch --import key.asc >/dev/null 2>&1 || die "Failed to import Easy-RSA release signing key."
	  local imported_fpr
	  imported_fpr="$(gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
	  [ "$imported_fpr" = "$EASYRSA_GPG_FINGERPRINT" ] || die "Easy-RSA signing key fingerprint mismatch (got $imported_fpr)."
	  gpg --batch --status-fd 1 --verify easyrsa.tgz.sig easyrsa.tgz 2>/dev/null | grep -q "^\[GNUPG:\] GOODSIG" || \
		  die "Easy-RSA source signature verification FAILED. Refusing to install."
	  log_ok "Signature verified: Easy-RSA ${EASYRSA_VERSION} source is authentic."

	  tar xzf easyrsa.tgz
	) || die "Easy-RSA verification/extraction failed."

	ensure_dir "$OPT_DIR" 0755
	rm -rf "$EASYRSA_INSTALL_DIR"
	mv "$workdir/EasyRSA-${EASYRSA_VERSION}" "$EASYRSA_INSTALL_DIR"
	rm -rf "$workdir"
	chmod 0755 "$EASYRSA_BIN"
	log_ok "Easy-RSA ${EASYRSA_VERSION} installed to ${EASYRSA_INSTALL_DIR}"
}

_easyrsa() {
	( umask 077
	  cd "$EASYRSA_INSTALL_DIR" && \
	  EASYRSA_PKI="$PKI_DIR" \
	  EASYRSA_BATCH=1 \
	  EASYRSA_ALGO="${DEFAULT_EASYRSA_ALGO:-ec}" \
	  EASYRSA_CURVE="${DEFAULT_EASYRSA_CURVE:-secp384r1}" \
	  EASYRSA_DIGEST="${DEFAULT_EASYRSA_DIGEST:-sha256}" \
	  EASYRSA_CA_EXPIRE="${DEFAULT_CA_EXPIRE_DAYS:-3650}" \
	  EASYRSA_CERT_EXPIRE="${DEFAULT_CERT_EXPIRE_DAYS:-825}" \
	  EASYRSA_CRL_DAYS="${DEFAULT_CRL_DAYS:-180}" \
	  EASYRSA_REQ_CN="${1:-OpenVPN-CA}" \
	  ./easyrsa "${@:2}" )
}

pki_init() {
	local ca_cn="${1:-OpenVPN-CA}"
	[ -f "${PKI_DIR}/private/ca.key" ] && { log_warn "PKI already initialized; skipping."; return 0; }
	log_step "Initializing PKI (CA: ${ca_cn})"
	ensure_dir "$(dirname "$PKI_DIR")" 0755
	_easyrsa "$ca_cn" init-pki >/dev/null || die "easyrsa init-pki failed"
	_easyrsa "$ca_cn" build-ca nopass >/dev/null || die "easyrsa build-ca failed"
	# Some openssl versions warn (harmlessly) on the first `openssl ca`
	# invocation if index.txt.attr doesn't exist yet; easy-rsa doesn't
	# pre-create it, so we do, to keep first-issuance output clean.
	[ -f "${PKI_DIR}/index.txt.attr" ] || : >"${PKI_DIR}/index.txt.attr"
	chmod 0700 "$PKI_DIR"
	chmod 0700 "${PKI_DIR}/private"
	log_ok "Certificate authority created."

	log_info "Generating tls-crypt key"
	local ovpn_bin
	ovpn_bin="$(ovpn_engine_resolve_bin)"
	( umask 077; "$ovpn_bin" --genkey secret "${PKI_DIR}/tls-crypt.key" ) || die "Failed to generate tls-crypt key"

	log_info "Generating initial CRL"
	_easyrsa "$ca_cn" gen-crl >/dev/null || die "easyrsa gen-crl failed"
	chmod 0644 "${PKI_DIR}/crl.pem"
}

pki_build_server() {
	local name="${1:-server}"
	[ -f "${PKI_DIR}/issued/${name}.crt" ] && { log_warn "Server certificate '${name}' already exists; skipping."; return 0; }
	log_step "Issuing server certificate '${name}'"
	_easyrsa "$name" build-server-full "$name" nopass >/dev/null || die "Failed to build server certificate."
	log_ok "Server certificate issued."
}

pki_build_client() {
	local name="$1"
	valid_client_name "$name" || die "Invalid client name: '$name'"
	[ -f "${PKI_DIR}/issued/${name}.crt" ] && die "A client named '${name}' already exists."
	log_step "Issuing client certificate '${name}'"
	_easyrsa "$name" build-client-full "$name" nopass >/dev/null || die "Failed to build client certificate."
	ensure_dir "${VAR_DIR}/clients" 0700
	date -u '+%Y-%m-%dT%H:%M:%SZ' >"${VAR_DIR}/clients/${name}.created"
	log_ok "Client certificate '${name}' issued."
}

pki_revoke_client() {
	local name="$1"
	valid_client_name "$name" || die "Invalid client name: '$name'"
	[ -f "${PKI_DIR}/issued/${name}.crt" ] || die "No such client: '${name}'"
	log_step "Revoking client '${name}'"
	_easyrsa "$name" revoke "$name" >/dev/null || die "Failed to revoke client '${name}'."
	_easyrsa "$name" gen-crl >/dev/null || die "Failed to regenerate CRL."
	chmod 0644 "${PKI_DIR}/crl.pem"
	pki_sync_crl
	date -u '+%Y-%m-%dT%H:%M:%SZ' >"${VAR_DIR}/clients/${name}.revoked"
	log_ok "Client '${name}' revoked and CRL updated."
}

# pki_sync_crl: copy the current CRL to wherever the running server configs
# expect it (world-readable, since OpenVPN reads it after dropping privileges).
pki_sync_crl() {
	[ -f "${PKI_DIR}/crl.pem" ] || return 0
	ensure_dir "${OPENVPN_ETC_DIR}/server-manager" 0755
	install -o root -g root -m 0644 "${PKI_DIR}/crl.pem" "${OPENVPN_ETC_DIR}/server-manager/crl.pem"
}

pki_renew_client() {
	local name="$1"
	valid_client_name "$name" || die "Invalid client name: '$name'"
	[ -f "${PKI_DIR}/issued/${name}.crt" ] || die "No such client: '${name}'"
	log_step "Renewing client '${name}'"
	_easyrsa "$name" renew "$name" nopass >/dev/null || die "Failed to renew client '${name}'."
	_easyrsa "$name" gen-crl >/dev/null || true
	chmod 0644 "${PKI_DIR}/crl.pem"
	pki_sync_crl
	date -u '+%Y-%m-%dT%H:%M:%SZ' >"${VAR_DIR}/clients/${name}.renewed"
	log_ok "Client '${name}' renewed."
}

# pki_list_clients: prints "name status expiry" for every issued client cert
# (excludes the server cert itself).
pki_list_clients() {
	local server_name
	server_name="$(state_get SERVER_CERT_NAME server)"
	[ -f "${PKI_DIR}/index.txt" ] || return 0
	awk -F'\t' -v server="/CN=${server_name}" '
		$6 !~ server && $6 ~ /\/CN=/ {
			status = ($1=="V") ? "valid" : ($1=="R") ? "revoked" : "expired"
			cn = $6; sub(/.*\/CN=/, "", cn)
			print cn, status, $2
		}' "${PKI_DIR}/index.txt"
}

pki_client_status() {
	local name="$1"
	pki_list_clients | awk -v n="$name" '$1==n{print $2; found=1} END{if(!found) exit 1}'
}

pki_ca_expiry() {
	[ -f "${PKI_DIR}/ca.crt" ] || return 1
	openssl x509 -enddate -noout -in "${PKI_DIR}/ca.crt" 2>/dev/null | cut -d= -f2
}

pki_server_expiry() {
	local name="${1:-server}"
	[ -f "${PKI_DIR}/issued/${name}.crt" ] || return 1
	openssl x509 -enddate -noout -in "${PKI_DIR}/issued/${name}.crt" 2>/dev/null | cut -d= -f2
}

pki_client_expiry() {
	local name="$1"
	[ -f "${PKI_DIR}/issued/${name}.crt" ] || return 1
	openssl x509 -enddate -noout -in "${PKI_DIR}/issued/${name}.crt" 2>/dev/null | cut -d= -f2
}
