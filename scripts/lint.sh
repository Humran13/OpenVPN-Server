#!/usr/bin/env bash
# lint.sh — run every static check this project uses, locally, the same way
# CI does. Requires Docker (for shellcheck/bats) or a local shellcheck.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> bash -n (syntax)"
for f in install.sh bin/ovpn lib/*.sh tests/integration/run.sh; do
	bash -n "$f"
done
echo "OK"

echo "==> shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
	shellcheck -S warning -x install.sh bin/ovpn lib/*.sh
else
	docker run --rm -v "${ROOT_DIR}:/mnt" -w /mnt koalaman/shellcheck:stable \
		-S warning -x install.sh bin/ovpn lib/*.sh
fi
echo "OK"

echo "==> bats unit tests"
docker run --rm -v "${ROOT_DIR}:/code" -w /code bats/bats:latest tests/unit/

echo
echo "All static checks passed."
