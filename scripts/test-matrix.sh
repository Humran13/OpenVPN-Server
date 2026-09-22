#!/usr/bin/env bash
# test-matrix.sh — run the full Docker-based integration scenario matrix
# across a set of Ubuntu base images. This is the manual pre-release check
# referenced from .github/workflows/ci.yml; it is intentionally NOT run on
# every CI push (too slow/expensive for that), but should be run before
# tagging a release.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGES="${IMAGES:-ubuntu:18.04 ubuntu:20.04 ubuntu:22.04 ubuntu:24.04 ubuntu:26.04}"
SCENARIOS="${SCENARIOS:-udp tcp dual revoke idempotent backup_restore uninstall_reinstall multi_client}"

pass=0
fail=0
failed_list=()

for img in $IMAGES; do
	for s in $SCENARIOS; do
		echo
		echo "###################################################################"
		echo "# ${img} :: ${s}"
		echo "###################################################################"
		if BASE_IMAGE="$img" SCENARIO="$s" bash tests/integration/run.sh; then
			pass=$((pass + 1))
		else
			fail=$((fail + 1))
			failed_list+=("${img}::${s}")
		fi
	done
done

echo
echo "==================================================================="
echo "Matrix complete: ${pass} passed, ${fail} failed"
if [ "$fail" -gt 0 ]; then
	printf 'FAILED: %s\n' "${failed_list[@]}"
	exit 1
fi
exit 0
