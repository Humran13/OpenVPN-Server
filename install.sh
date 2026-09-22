#!/usr/bin/env bash
# install.sh — OpenVPN Server Manager installer for Ubuntu.
#
# Designed to be safe when run as:
#   curl -fsSL https://raw.githubusercontent.com/Humran13/OpenVPN-Server/main/install.sh | sudo bash
#
# Because stdin is the piped script itself in that invocation, ALL
# interactive prompts in this project read from /dev/tty (see
# lib/common.sh: tty_read/have_tty), never from stdin directly.
set -euo pipefail
umask 022

GITHUB_REPO="${OVPN_GITHUB_REPO:-Humran13/OpenVPN-Server}"
INSTALL_OPT_DIR="/opt/openvpn-server-manager"

# ---------------------------------------------------------------------------
# 0. root check
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
	echo "This installer must be run as root, e.g.:" >&2
	echo "  curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh | sudo bash" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# 1. locate or fetch the project source (lib/, bin/, config/)
# ---------------------------------------------------------------------------
_self_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
	_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
fi

SRC_DIR=""
if [ -n "$_self_dir" ] && [ -d "${_self_dir}/lib" ] && [ -d "${_self_dir}/bin" ] && [ -d "${_self_dir}/config" ]; then
	# Running from a real checkout (local dev / CI), not via curl|bash.
	SRC_DIR="$_self_dir"
else
	echo "==> Fetching OpenVPN Server Manager source..."
	command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl; }
	command -v tar >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq tar; }

	_tmp="$(mktemp -d /tmp/ovpn-install.XXXXXX)"
	_tag="$(curl -fsSL --max-time 10 "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"(v[0-9.]+)".*/\1/' || true)"
	if [ -n "$_tag" ]; then
		_url="https://github.com/${GITHUB_REPO}/archive/refs/tags/${_tag}.tar.gz"
	else
		_url="https://github.com/${GITHUB_REPO}/archive/refs/heads/main.tar.gz"
	fi
	if ! curl -fsSL --max-time 60 -o "${_tmp}/src.tar.gz" "$_url"; then
		echo "Failed to download project source from ${_url}" >&2
		exit 1
	fi
	tar -xzf "${_tmp}/src.tar.gz" -C "$_tmp"
	SRC_DIR="$(find "$_tmp" -maxdepth 1 -type d -name 'OpenVPN-Server-*' | head -n1)"
	[ -n "$SRC_DIR" ] || { echo "Unexpected archive layout after download." >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# 2. install project files into their runtime location
# ---------------------------------------------------------------------------
mkdir -p "$INSTALL_OPT_DIR"
cp -a "${SRC_DIR}/." "$INSTALL_OPT_DIR/"
chmod +x "${INSTALL_OPT_DIR}/bin/ovpn" "${INSTALL_OPT_DIR}/install.sh" 2>/dev/null || true
[ -n "${_tmp:-}" ] && rm -rf "$_tmp"

# shellcheck source=/dev/null
for _f in common os validate state network firewall systemd openvpn_install pki \
	server_config client_config menu status diagnostics logs backup update \
	repair uninstall version; do
	. "${INSTALL_OPT_DIR}/lib/${_f}.sh"
done
unset _f

# ---------------------------------------------------------------------------
# 3. OS / architecture checks
# ---------------------------------------------------------------------------
log_step "Detecting operating system"
os_detect || die "Could not detect the operating system (missing /etc/os-release). This installer supports Ubuntu only."
log_info "Detected: $(os_summary)"

if [ "${OS_ID}" != "ubuntu" ]; then
	die "This installer supports Ubuntu only (detected: ${OS_ID:-unknown}). Aborting."
fi
os_is_supported || die "Ubuntu ${OS_VERSION_ID} is older than the minimum supported version (${MIN_SUPPORTED_UBUNTU_VERSION}). Aborting."
os_is_tested || log_warn "Ubuntu ${OS_VERSION_ID} (${OS_CODENAME}) was not part of the explicitly tested matrix (tested: ${TESTED_UBUNTU_CODENAMES}). Proceeding, but please report any issues."
if os_is_eol_warning_needed; then
	log_warn "Ubuntu 18.04 (bionic) is END-OF-LIFE outside paid Extended Security Maintenance."
	log_warn "For an Internet-facing production VPN server, a currently supported Ubuntu LTS release is strongly recommended."
fi

ARCH="$(os_arch)"
[ "$ARCH" != "unknown" ] || die "Unsupported CPU architecture: $(uname -m). This installer supports amd64/arm64 only."
log_info "Architecture: ${ARCH}"

# ---------------------------------------------------------------------------
# 4. detect pre-existing, unrelated OpenVPN deployments
# ---------------------------------------------------------------------------
log_step "Checking for existing OpenVPN configuration"
_existing=0
# Legacy openvpn@.service configs live directly under /etc/openvpn/*.conf;
# the newer openvpn-server@.service style uses /etc/openvpn/server/*.conf.
# Our own generated configs live in their own server-manager/ subdirectory
# and are deliberately not matched by either of these.
if [ -d /etc/openvpn ] && find /etc/openvpn -maxdepth 1 -name '*.conf' 2>/dev/null | grep -q .; then
	_existing=1
fi
if [ -d /etc/openvpn/server ] && find /etc/openvpn/server -maxdepth 1 -name '*.conf' 2>/dev/null | grep -q .; then
	_existing=1
fi
# Check for INSTANTIATED units, not just the distro package's bundled unit
# *templates* (openvpn@.service / openvpn-server@.service), which are
# always present once the openvpn package is installed — including by our
# own engine install — and would otherwise cause a false positive on every
# subsequent run.
if systemctl list-units --all --no-legend 2>/dev/null | grep -qE '^[[:space:]]*(openvpn|openvpn-server)@[^.[:space:]]+\.service'; then
	_existing=1
fi
if [ "$_existing" -eq 1 ] && [ ! -f "${STATE_FILE}" ]; then
	log_warn "An existing OpenVPN configuration was detected that was NOT created by this project."
	log_warn "This installer will NOT modify or remove it. OpenVPN Server Manager uses its own"
	log_warn "config directory (${SRV_CONF_DIR}), systemd units (openvpn-server-manager@*) and"
	log_warn "distinct listener ports, so it can safely coexist alongside your existing setup —"
	log_warn "as long as the ports you choose next do not collide with it."
	confirm "Continue installing OpenVPN Server Manager alongside the existing OpenVPN setup?" || { log_info "Aborted by user."; exit 1; }
fi

# ---------------------------------------------------------------------------
# 5. base packages
# ---------------------------------------------------------------------------
log_step "Installing base dependencies"
export DEBIAN_FRONTEND=noninteractive
run_quiet apt-get update
run_quiet apt-get install -y --no-install-recommends \
	curl ca-certificates gnupg iproute2 iptables openssl net-tools || die "Failed to install base dependencies."

net_tun_available || die "TUN device support is not available on this host/kernel. OpenVPN requires /dev/net/tun."

# ---------------------------------------------------------------------------
# 6. runtime directories
# ---------------------------------------------------------------------------
ensure_dir "$ETC_DIR" 0700
ensure_dir "$VAR_DIR" 0700
ensure_dir "${VAR_DIR}/clients" 0700
ensure_dir "$LOG_DIR" 0750
ensure_dir "$CLIENT_EXPORT_DIR" 0700
ensure_dir "$SRV_CONF_DIR" 0755

# ---------------------------------------------------------------------------
# 7. OpenVPN engine
# ---------------------------------------------------------------------------
ovpn_engine_install "$OS_CODENAME" "$ARCH"
OVPN_BIN="$(ovpn_engine_resolve_bin)"
ovpn_engine_test_binary "$OVPN_BIN"
state_set OPENVPN_INSTALL_METHOD "$OPENVPN_INSTALL_METHOD"
state_set OPENVPN_INSTALL_BIN "$OVPN_BIN"

# ---------------------------------------------------------------------------
# 8. PKI
# ---------------------------------------------------------------------------
pki_install_easyrsa
pki_init "OpenVPN-CA-$(hostname -s 2>/dev/null || echo server)"
pki_build_server "server"
state_set SERVER_CERT_NAME "server"

# ---------------------------------------------------------------------------
# 9. connection settings: interactive wizard, or non-interactive env-driven
#    configuration (used by automated tests / unattended deployments).
# ---------------------------------------------------------------------------
if [ -n "$(state_get LISTENERS "")" ] && [ "${OVPN_FORCE_RECONFIGURE:-0}" != "1" ]; then
	log_info "Existing listener configuration found in state; keeping it (rerun is idempotent)."
	log_info "Use 'sudo ovpn settings' afterwards to reconfigure, or set OVPN_FORCE_RECONFIGURE=1 before reinstalling."
elif [ "${OVPN_NONINTERACTIVE:-0}" = "1" ]; then
	log_step "Applying non-interactive configuration from environment variables"
	_mode="${OVPN_MODE:-udp}"
	_famsuf=4
	[ "${OVPN_IP_FAMILY:-ipv4}" = "dual" ] && _famsuf=6
	case "$_mode" in
		udp) _listeners="udp${OVPN_UDP_PORT:-$DEFAULT_UDP_PORT}|udp|${OVPN_UDP_PORT:-$DEFAULT_UDP_PORT}|ovpn0|${_famsuf}" ;;
		tcp) _listeners="tcp${OVPN_TCP_PORT:-$DEFAULT_TCP_PORT}|tcp|${OVPN_TCP_PORT:-$DEFAULT_TCP_PORT}|ovpn0|${_famsuf}" ;;
		dual) _listeners="udp${OVPN_UDP_PORT:-$DEFAULT_UDP_PORT}|udp|${OVPN_UDP_PORT:-$DEFAULT_UDP_PORT}|ovpn0|${_famsuf},tcp${OVPN_TCP_PORT:-$DEFAULT_TCP_PORT}|tcp|${OVPN_TCP_PORT:-$DEFAULT_TCP_PORT}|ovpn1|${_famsuf}" ;;
		*) die "Unknown OVPN_MODE '${_mode}' (expected udp|tcp|dual)" ;;
	esac
	state_set LISTENERS "$_listeners"
	state_set IP_FAMILY "${OVPN_IP_FAMILY:-ipv4}"
	state_set ROUTING_MODE "${OVPN_ROUTING:-full}"
	state_set SPLIT_NETWORKS "${OVPN_SPLIT_NETWORKS:-}"
	state_set DNS_MODE "${OVPN_DNS:-current}"
	state_set DNS_CUSTOM "${OVPN_DNS_CUSTOM:-}"
	state_set PUBLIC_HOST "${OVPN_PUBLIC_HOST:-$(net_public_ip)}"
else
	have_tty || die "No interactive terminal available and OVPN_NONINTERACTIVE is not set. Re-run with OVPN_NONINTERACTIVE=1 and OVPN_* variables for unattended install, or run this from a real terminal (curl|sudo bash still works via /dev/tty)."
	wizard_run
fi

# ---------------------------------------------------------------------------
# 10. generate server configs, systemd units, firewall, forwarding
# ---------------------------------------------------------------------------
log_step "Generating server configuration"
srvcfg_generate_all

log_step "Installing systemd units"
systemd_install_template "$OVPN_BIN" "$SRV_CONF_DIR"

log_step "Enabling IP forwarding"
_family="$(state_get IP_FAMILY ipv4)"
net_enable_forwarding "$([ "$_family" = "dual" ] && echo both || echo v4)"

log_step "Configuring firewall"
fw_configure_from_state
log_ok "Firewall backend in use: $(fw_summary)"

log_step "Starting OpenVPN listeners"
systemctl daemon-reload
IFS=',' read -ra _entries <<<"$(state_get LISTENERS "")"
for _entry in "${_entries[@]}"; do
	[ -n "$_entry" ] || continue
	IFS='|' read -r _name _proto _port _dev _fam <<<"$_entry"
	systemd_enable_instance "$_name" || die "Failed to start listener '${_name}'. Check: journalctl -u openvpn-server-manager@${_name}"
done

sleep 2
_all_ok=1
for _entry in "${_entries[@]}"; do
	[ -n "$_entry" ] || continue
	IFS='|' read -r _name _proto _port _dev _fam <<<"$_entry"
	if [ "$(systemd_status_instance "$_name")" != "active" ]; then
		_all_ok=0
		log_error "Listener '${_name}' failed to start:"
		journalctl -u "openvpn-server-manager@${_name}" -n 30 --no-pager >&2 || true
	fi
done
[ "$_all_ok" -eq 1 ] || die "One or more listeners failed to start. See errors above."

# ---------------------------------------------------------------------------
# 11. manager command + final state
# ---------------------------------------------------------------------------
ln -sf "${INSTALL_OPT_DIR}/bin/ovpn" /usr/local/bin/ovpn
state_set MANAGER_VERSION "$MANAGER_VERSION"
state_set INSTALL_DATE "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

echo
log_ok "OpenVPN Server Manager v${MANAGER_VERSION} installed successfully."
echo
echo "  Manage your server:   sudo ovpn"
echo "  Create a client:      sudo ovpn client add myclient"
echo "  Check health:         sudo ovpn diagnostics"
echo "  Client profiles are exported to: ${CLIENT_EXPORT_DIR}"
echo
