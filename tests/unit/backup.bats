#!/usr/bin/env bats
# Unit tests for lib/backup.sh — archive validation and restore safety.
# Regression coverage for a real bug found in integration testing: tar
# archives created with `-C dir .` list entries as "./MANIFEST" etc, which
# a naive `^MANIFEST$` match against the listing silently never matches.

setup() {
	ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
	ETC_DIR="$(mktemp -d)"
	VAR_DIR="$(mktemp -d)"
	STATE_FILE="${ETC_DIR}/state.conf"
	source "${ROOT_DIR}/lib/common.sh"
	source "${ROOT_DIR}/lib/state.sh"
	source "${ROOT_DIR}/lib/backup.sh"
	WORK="$(mktemp -d)"
}

teardown() { rm -rf "$ETC_DIR" "$VAR_DIR" "$WORK"; }

make_valid_archive() {
	local dir="${WORK}/stage"
	mkdir -p "${dir}/pki"
	echo fake-ca >"${dir}/pki/ca.crt"
	echo "manager_version=1.0.0" >"${dir}/MANIFEST"
	tar -czf "${WORK}/backup.tar.gz" -C "$dir" .
}

@test "backup_validate accepts a real archive built the same way backup_create builds one" {
	make_valid_archive
	run backup_validate "${WORK}/backup.tar.gz"
	[ "$status" -eq 0 ]
}

@test "backup_validate rejects a missing file" {
	run backup_validate "${WORK}/does-not-exist.tar.gz"
	[ "$status" -ne 0 ]
}

@test "backup_validate rejects an archive without MANIFEST" {
	local dir="${WORK}/stage2"
	mkdir -p "${dir}/pki"
	echo x >"${dir}/pki/ca.crt"
	tar -czf "${WORK}/no-manifest.tar.gz" -C "$dir" .
	run backup_validate "${WORK}/no-manifest.tar.gz"
	[ "$status" -ne 0 ]
	[[ "$output" == *MANIFEST* ]]
}

@test "backup_validate rejects an archive without pki/" {
	local dir="${WORK}/stage3"
	mkdir -p "$dir"
	echo "manager_version=1.0.0" >"${dir}/MANIFEST"
	tar -czf "${WORK}/no-pki.tar.gz" -C "$dir" .
	run backup_validate "${WORK}/no-pki.tar.gz"
	[ "$status" -ne 0 ]
}

@test "backup_validate rejects path traversal entries" {
	# A well-behaved tar strips leading '../' at CREATE time, so we can't
	# easily produce a hostile archive with common CLI tools. What matters
	# is that backup_validate's own parsing of `tar -tzf`'s listing rejects
	# traversal entries wherever they came from (a hand-crafted hostile
	# archive built with a different, non-sanitizing tool, for example) —
	# so we stub the listing itself, exercising that parsing directly.
	touch "${WORK}/traversal.tar.gz"
	tar() {
		if [ "$1" = "-tzf" ]; then
			printf 'MANIFEST\npki/ca.crt\n../../etc/passwd\n'
		else
			command tar "$@"
		fi
	}
	run backup_validate "${WORK}/traversal.tar.gz"
	[ "$status" -ne 0 ]
	[[ "$output" == *"unsafe paths"* ]]
}

@test "backup_validate rejects an archive with an absolute path entry" {
	touch "${WORK}/abs.tar.gz"
	tar() {
		if [ "$1" = "-tzf" ]; then
			printf 'MANIFEST\npki/ca.crt\n/etc/passwd\n'
		else
			command tar "$@"
		fi
	}
	run backup_validate "${WORK}/abs.tar.gz"
	[ "$status" -ne 0 ]
	[[ "$output" == *"unsafe paths"* ]]
}

@test "backup_validate rejects a corrupt/non-gzip file" {
	echo "not a tarball" >"${WORK}/bogus.tar.gz"
	run backup_validate "${WORK}/bogus.tar.gz"
	[ "$status" -ne 0 ]
}

@test "backup_create produces an archive that passes its own validation" {
	PKI_DIR="${WORK}/pki"
	mkdir -p "${PKI_DIR}/issued" "${PKI_DIR}/private"
	echo fake-ca >"${PKI_DIR}/ca.crt"
	SRV_CONF_DIR="${WORK}/srvconf"
	FW_STATE_DIR="${WORK}/fw"
	state_set PUBLIC_HOST "vpn.example.com"
	out="$(backup_create "${WORK}/real-backup.tar.gz")"
	[ -f "$out" ]
	run backup_validate "$out"
	[ "$status" -eq 0 ]
}
