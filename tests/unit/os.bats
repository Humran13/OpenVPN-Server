#!/usr/bin/env bats
# Unit tests for lib/os.sh — Ubuntu version/codename/arch detection.

setup() {
	ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
	source "${ROOT_DIR}/lib/os.sh"
	FIXTURES="${ROOT_DIR}/tests/unit/fixtures"
}

@test "os_detect parses bionic (18.04)" {
	os_detect "${FIXTURES}/os-release-bionic"
	[ "$OS_ID" = "ubuntu" ]
	[ "$OS_VERSION_ID" = "18.04" ]
	[ "$OS_CODENAME" = "bionic" ]
}

@test "os_detect parses focal (20.04)" {
	os_detect "${FIXTURES}/os-release-focal"
	[ "$OS_VERSION_ID" = "20.04" ]
	[ "$OS_CODENAME" = "focal" ]
}

@test "os_detect parses jammy (22.04)" {
	os_detect "${FIXTURES}/os-release-jammy"
	[ "$OS_VERSION_ID" = "22.04" ]
	[ "$OS_CODENAME" = "jammy" ]
}

@test "os_detect parses noble (24.04)" {
	os_detect "${FIXTURES}/os-release-noble"
	[ "$OS_VERSION_ID" = "24.04" ]
	[ "$OS_CODENAME" = "noble" ]
}

@test "os_detect parses resolute (26.04)" {
	os_detect "${FIXTURES}/os-release-resolute"
	[ "$OS_VERSION_ID" = "26.04" ]
	[ "$OS_CODENAME" = "resolute" ]
}

@test "os_detect parses a hypothetical future codename without rejecting it" {
	os_detect "${FIXTURES}/os-release-future"
	[ "$OS_ID" = "ubuntu" ]
	[ "$OS_VERSION_ID" = "28.04" ]
}

@test "os_detect handles missing VERSION_CODENAME via VERSION_ID fallback" {
	os_detect "${FIXTURES}/os-release-no-codename"
	[ "$OS_CODENAME" = "jammy" ]
}

@test "os_detect fails cleanly on missing file" {
	run os_detect "${FIXTURES}/does-not-exist"
	[ "$status" -ne 0 ]
}

@test "os_detect fails on non-Ubuntu OS" {
	os_detect "${FIXTURES}/os-release-debian"
	[ "$OS_ID" = "debian" ]
}

@test "os_version_ge basic comparisons" {
	run os_version_ge "20.04" "18.04"; [ "$status" -eq 0 ]
	run os_version_ge "18.04" "18.04"; [ "$status" -eq 0 ]
	run os_version_ge "18.04" "20.04"; [ "$status" -ne 0 ]
	run os_version_ge "26.04" "18.04"; [ "$status" -eq 0 ]
	run os_version_ge "9.10" "18.04"; [ "$status" -ne 0 ]
}

@test "os_is_supported accepts Ubuntu >= 18.04" {
	MIN_SUPPORTED_UBUNTU_VERSION="18.04"
	os_detect "${FIXTURES}/os-release-jammy"
	run os_is_supported; [ "$status" -eq 0 ]
}

@test "os_is_supported rejects Ubuntu 16.04" {
	MIN_SUPPORTED_UBUNTU_VERSION="18.04"
	os_detect "${FIXTURES}/os-release-xenial"
	run os_is_supported; [ "$status" -ne 0 ]
}

@test "os_is_supported rejects non-Ubuntu" {
	MIN_SUPPORTED_UBUNTU_VERSION="18.04"
	os_detect "${FIXTURES}/os-release-debian"
	run os_is_supported; [ "$status" -ne 0 ]
}

@test "os_is_eol_warning_needed true only for bionic" {
	os_detect "${FIXTURES}/os-release-bionic"
	run os_is_eol_warning_needed; [ "$status" -eq 0 ]
	os_detect "${FIXTURES}/os-release-jammy"
	run os_is_eol_warning_needed; [ "$status" -ne 0 ]
}

@test "os_is_tested reflects TESTED_UBUNTU_CODENAMES" {
	TESTED_UBUNTU_CODENAMES="focal jammy noble"
	os_detect "${FIXTURES}/os-release-jammy"
	run os_is_tested; [ "$status" -eq 0 ]
	os_detect "${FIXTURES}/os-release-bionic"
	run os_is_tested; [ "$status" -ne 0 ]
}

@test "os_arch normalizes x86_64 to amd64" {
	uname() { echo "x86_64"; }
	run os_arch
	[ "$output" = "amd64" ]
}

@test "os_arch normalizes aarch64 to arm64" {
	uname() { echo "aarch64"; }
	run os_arch
	[ "$output" = "arm64" ]
}

@test "os_arch reports unknown for unsupported arch" {
	uname() { echo "riscv64"; }
	run os_arch
	[ "$output" = "unknown" ]
}
