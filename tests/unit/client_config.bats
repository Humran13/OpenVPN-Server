#!/usr/bin/env bats
# Unit tests for lib/client_config.sh — inline .ovpn profile generation.

setup() {
	ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
	ETC_DIR="$(mktemp -d)"
	PKI_DIR="$(mktemp -d)"
	STATE_FILE="${ETC_DIR}/state.conf"
	source "${ROOT_DIR}/lib/common.sh"
	source "${ROOT_DIR}/lib/state.sh"
	source "${ROOT_DIR}/lib/validate.sh"
	source "${ROOT_DIR}/lib/client_config.sh"

	mkdir -p "${PKI_DIR}/issued" "${PKI_DIR}/private"
	echo "-----BEGIN CERTIFICATE-----FAKE-CA-----END CERTIFICATE-----" >"${PKI_DIR}/ca.crt"
	echo "-----BEGIN CERTIFICATE-----FAKE-CLIENT-CERT-----END CERTIFICATE-----" >"${PKI_DIR}/issued/alice.crt"
	echo "-----BEGIN PRIVATE KEY-----FAKE-CLIENT-KEY-----END PRIVATE KEY-----" >"${PKI_DIR}/private/alice.key"
	echo "-----BEGIN OpenVPN Static key V1-----FAKE-TLS-CRYPT-----END OpenVPN Static key V1-----" >"${PKI_DIR}/tls-crypt.key"

	# openssl x509 is used to re-print the cert; stub it so the fixture
	# "certificate" (not real DER/PEM) round-trips instead of failing.
	openssl() { if [ "$1" = "x509" ]; then cat "${PKI_DIR}/issued/alice.crt"; else command openssl "$@"; fi; }
	export -f openssl

	state_set PUBLIC_HOST "vpn.example.com"
	state_set LISTENERS "udp1194|udp|1194|ovpn0|4,tcp443|tcp|443|ovpn1|4"

	# pki_client_status is normally provided by lib/pki.sh; stub it minimally.
	pki_client_status() { echo valid; }

	OUT_DIR="$(mktemp -d)"
}

teardown() { rm -rf "$ETC_DIR" "$PKI_DIR" "$OUT_DIR"; }

@test "ccfg_export rejects an invalid client name" {
	run ccfg_export '../evil' "${OUT_DIR}/out.ovpn"
	[ "$status" -ne 0 ]
}

@test "ccfg_export fails when the client certificate does not exist" {
	run ccfg_export "nobody" "${OUT_DIR}/out.ovpn"
	[ "$status" -ne 0 ]
}

@test "ccfg_export refuses to export a revoked client" {
	pki_client_status() { echo revoked; }
	run ccfg_export "alice" "${OUT_DIR}/out.ovpn"
	[ "$status" -ne 0 ]
}

@test "ccfg_export produces a client with both remotes in configured order" {
	ccfg_export "alice" "${OUT_DIR}/out.ovpn"
	[ -f "${OUT_DIR}/out.ovpn" ]
	grep -n "^remote " "${OUT_DIR}/out.ovpn" > "${OUT_DIR}/remotes.txt"
	[ "$(wc -l <"${OUT_DIR}/remotes.txt")" -eq 2 ]
	first="$(sed -n '1p' "${OUT_DIR}/remotes.txt")"
	second="$(sed -n '2p' "${OUT_DIR}/remotes.txt")"
	[[ "$first" == *"1194 udp"* ]]
	[[ "$second" == *"443 tcp"* ]]
}

@test "ccfg_export embeds ca/cert/key/tls-crypt inline blocks" {
	ccfg_export "alice" "${OUT_DIR}/out.ovpn"
	grep -q '<ca>' "${OUT_DIR}/out.ovpn"
	grep -q '</ca>' "${OUT_DIR}/out.ovpn"
	grep -q '<cert>' "${OUT_DIR}/out.ovpn"
	grep -q '<key>' "${OUT_DIR}/out.ovpn"
	grep -q 'FAKE-CLIENT-KEY' "${OUT_DIR}/out.ovpn"
	grep -q '<tls-crypt>' "${OUT_DIR}/out.ovpn"
	grep -q 'client' "${OUT_DIR}/out.ovpn"
	grep -q '^dev tun$' "${OUT_DIR}/out.ovpn"
	grep -q '^remote-cert-tls server$' "${OUT_DIR}/out.ovpn"
}

@test "ccfg_export writes the profile with 0600 permissions" {
	ccfg_export "alice" "${OUT_DIR}/out.ovpn"
	perm="$(stat -c '%a' "${OUT_DIR}/out.ovpn" 2>/dev/null || stat -f '%Lp' "${OUT_DIR}/out.ovpn")"
	[ "$perm" = "600" ]
}
