#!/usr/bin/env bash
# common.sh — shared logging, error handling and path helpers.
# Sourced by every other lib/*.sh file and by bin/ovpn.

if [ -n "${_OVPN_COMMON_LOADED:-}" ]; then
	return 0 2>/dev/null || exit 0
fi
_OVPN_COMMON_LOADED=1

set -o pipefail

# Resolve the manager's own root directory regardless of caller cwd.
OVPN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
OVPN_ROOT_DIR="$(cd "${OVPN_LIB_DIR}/.." >/dev/null 2>&1 && pwd)"
OVPN_CONFIG_DIR="${OVPN_ROOT_DIR}/config"

# shellcheck source=config/upstream.conf
[ -f "${OVPN_CONFIG_DIR}/upstream.conf" ] && . "${OVPN_CONFIG_DIR}/upstream.conf"
# shellcheck source=config/defaults.conf
[ -f "${OVPN_CONFIG_DIR}/defaults.conf" ] && . "${OVPN_CONFIG_DIR}/defaults.conf"

# Installed runtime paths (may be overridden by /etc/openvpn-server-manager/manager.conf)
OPT_DIR="${OPT_DIR:-${DEFAULT_OPT_DIR:-/opt/openvpn-server-manager}}"
ETC_DIR="${ETC_DIR:-${DEFAULT_ETC_DIR:-/etc/openvpn-server-manager}}"
VAR_DIR="${VAR_DIR:-${DEFAULT_VAR_DIR:-/var/lib/openvpn-server-manager}}"
LOG_DIR="${LOG_DIR:-${DEFAULT_LOG_DIR:-/var/log/openvpn-server-manager}}"
OPENVPN_ETC_DIR="${OPENVPN_ETC_DIR:-${DEFAULT_OPENVPN_ETC_DIR:-/etc/openvpn}}"
PKI_DIR="${PKI_DIR:-${DEFAULT_PKI_DIR:-/etc/openvpn-server-manager/pki}}"
CLIENT_EXPORT_DIR="${CLIENT_EXPORT_DIR:-${DEFAULT_CLIENT_EXPORT_DIR:-/root/openvpn-clients}}"
STATE_FILE="${STATE_FILE:-${ETC_DIR}/state.conf}"
MANAGER_LOG_FILE="${MANAGER_LOG_FILE:-${LOG_DIR}/manager.log}"

# Load manager.conf overrides if present (installed system only).
[ -f "${ETC_DIR}/manager.conf" ] && . "${ETC_DIR}/manager.conf"

# --- colors (disabled when not a tty or NO_COLOR set) --------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
	C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
	C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

# --- logging ---------------------------------------------------------------
_log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log_file_write() {
	[ -n "${MANAGER_LOG_FILE:-}" ] || return 0
	local dir
	dir="$(dirname "$MANAGER_LOG_FILE")"
	[ -d "$dir" ] 2>/dev/null && printf '%s\n' "$1" >>"$MANAGER_LOG_FILE" 2>/dev/null
	return 0
}

# All log_* functions write to stderr, never stdout — this keeps stdout
# free for functions that return real data via command substitution
# (e.g. `path="$(backup_create ...)"`); mixing log noise into stdout would
# silently corrupt any such capture.
log_info()  { printf '%s[INFO]%s  %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; _log_file_write "$(_log_ts) [INFO]  $*"; }
log_ok()    { printf '%s[ OK ]%s  %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; _log_file_write "$(_log_ts) [OK]    $*"; }
log_warn()  { printf '%s[WARN]%s  %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _log_file_write "$(_log_ts) [WARN]  $*"; }
log_error() { printf '%s[FAIL]%s  %s\n' "$C_RED" "$C_RESET" "$*" >&2; _log_file_write "$(_log_ts) [ERROR] $*"; }
log_step()  { printf '\n%s%s==>%s %s%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_BOLD" "$*$C_RESET" >&2; _log_file_write "$(_log_ts) [STEP]  $*"; }
die()       { log_error "$*"; exit 1; }

# --- basic environment guards ----------------------------------------------
require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		die "This command must be run as root (try: sudo ${0##*/} $*)"
	fi
}

is_root() { [ "$(id -u)" -eq 0 ]; }

# True if we have a usable interactive terminal for menus/prompts (either
# stdout is a tty, or /dev/tty can actually be opened read-write — the
# latter is what saves us under curl|bash). Deliberately tests by actually
# opening the device rather than checking permission bits: /dev/tty exists
# with rw permissions even when the process has no controlling terminal
# (e.g. `docker exec` without -t), where opening it fails with ENXIO.
have_tty() {
	[ -t 1 ] && return 0
	{ : <>/dev/tty; } 2>/dev/null
}

# Confirm a destructive action. Returns 0 (yes) / 1 (no).
# Honors --yes/-y and OVPN_ASSUME_YES=1 for non-interactive automation.
confirm() {
	local prompt="${1:-Are you sure?}"
	if [ "${OVPN_ASSUME_YES:-0}" = "1" ]; then
		return 0
	fi
	local reply=""
	if have_tty; then
		printf '%s [y/N]: ' "$prompt" >/dev/tty
		read -r reply </dev/tty 2>/dev/null || reply=""
	else
		printf '%s [y/N]: ' "$prompt"
		read -r reply || reply=""
	fi
	case "$reply" in
		[Yy]|[Yy][Ee][Ss]) return 0 ;;
		*) return 1 ;;
	esac
}

# --- interactive input helper (works even when stdin is a pipe, e.g. curl|bash) ---
# Reads a line of input from an interactive TTY if one is available (/dev/tty),
# falling back to plain stdin otherwise. This is what makes menus work when the
# installer itself was invoked as `curl -fsSL .../install.sh | sudo bash`.
tty_read() {
	local __var="$1" __prompt="${2:-}"
	local __val=""
	if have_tty; then
		[ -n "$__prompt" ] && printf '%s' "$__prompt" >/dev/tty
		IFS= read -r __val </dev/tty 2>/dev/null || __val=""
	else
		[ -n "$__prompt" ] && printf '%s' "$__prompt"
		IFS= read -r __val || __val=""
	fi
	printf -v "$__var" '%s' "$__val"
}

run_quiet() {
	# Run a command, only showing output on failure. Used to keep noisy
	# package-manager/build output out of the way unless something breaks.
	local out
	if ! out="$("$@" 2>&1)"; then
		printf '%s\n' "$out" >&2
		return 1
	fi
	[ -n "${OVPN_VERBOSE:-}" ] && printf '%s\n' "$out"
	return 0
}

ensure_dir() {
	local dir="$1" mode="${2:-0755}"
	[ -d "$dir" ] || mkdir -p "$dir"
	chmod "$mode" "$dir"
}

# Portable readlink -f (musl/busybox-safe fallback not needed on Ubuntu, but harmless).
abspath() {
	readlink -f "$1" 2>/dev/null || python3 -c "import os,sys;print(os.path.abspath(sys.argv[1]))" "$1" 2>/dev/null || printf '%s\n' "$1"
}
