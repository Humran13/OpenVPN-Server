#!/usr/bin/env bash
# os.sh — OS, codename, version and architecture detection.

if [ -n "${_OVPN_OS_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
_OVPN_OS_LOADED=1

# os_detect populates: OS_ID OS_VERSION_ID OS_CODENAME OS_PRETTY_NAME
# Reads from $1 if given (test override), else /etc/os-release.
os_detect() {
	local osrelease="${1:-/etc/os-release}"
	OS_ID=""; OS_VERSION_ID=""; OS_CODENAME=""; OS_PRETTY_NAME=""

	if [ ! -r "$osrelease" ]; then
		return 1
	fi

	local key val
	while IFS='=' read -r key val; do
		val="${val%\"}"; val="${val#\"}"
		case "$key" in
			ID) OS_ID="$val" ;;
			VERSION_ID) OS_VERSION_ID="$val" ;;
			VERSION_CODENAME) OS_CODENAME="$val" ;;
			PRETTY_NAME) OS_PRETTY_NAME="$val" ;;
			UBUNTU_CODENAME) [ -z "$OS_CODENAME" ] && OS_CODENAME="$val" ;;
		esac
	done <"$osrelease"

	# Older os-release files (e.g. very old bionic point releases) may lack
	# VERSION_CODENAME; derive it from VERSION_ID as a last resort.
	if [ -z "$OS_CODENAME" ]; then
		case "$OS_VERSION_ID" in
			18.04) OS_CODENAME="bionic" ;;
			20.04) OS_CODENAME="focal" ;;
			22.04) OS_CODENAME="jammy" ;;
			24.04) OS_CODENAME="noble" ;;
			26.04) OS_CODENAME="resolute" ;;
		esac
	fi
	[ -n "$OS_ID" ]
}

# os_arch returns a normalized architecture: amd64 | arm64 | unknown
os_arch() {
	local m
	m="$(uname -m)"
	case "$m" in
		x86_64|amd64) printf 'amd64\n' ;;
		aarch64|arm64) printf 'arm64\n' ;;
		*) printf 'unknown\n' ;;
	esac
}

# os_version_ge "20.04" "18.04" -> 0 (true) if first >= second
os_version_ge() {
	local a="$1" b="$2"
	[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" = "$a" ]
}

# os_is_supported: 0 if Ubuntu >= MIN_SUPPORTED_UBUNTU_VERSION
os_is_supported() {
	[ "$OS_ID" = "ubuntu" ] || return 1
	os_version_ge "$OS_VERSION_ID" "${MIN_SUPPORTED_UBUNTU_VERSION:-18.04}"
}

# os_is_tested: 0 if this exact codename was part of the explicitly tested matrix
os_is_tested() {
	local cn
	for cn in ${TESTED_UBUNTU_CODENAMES:-}; do
		[ "$cn" = "$OS_CODENAME" ] && return 0
	done
	return 1
}

# os_is_eol_warning_needed: 0 (warn) for Ubuntu 18.04 (bionic) — EOL outside ESM.
os_is_eol_warning_needed() {
	[ "$OS_CODENAME" = "bionic" ]
}

# os_summary prints a one-line human summary; used by status/diagnostics.
os_summary() {
	os_detect >/dev/null
	printf '%s (%s) - %s\n' "${OS_PRETTY_NAME:-unknown}" "${OS_CODENAME:-?}" "$(os_arch)"
}
