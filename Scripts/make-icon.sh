#!/usr/bin/env bash
#
# Pack AppIcon.iconset/ into Resources/AppIcon.icns.
#
# Idempotent: skips if AppIcon.icns already exists and --force is not given.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONSET_DIR="${REPO_ROOT}/AppIcon.iconset"
RES_DIR="${REPO_ROOT}/Resources"
ICNS_PATH="${RES_DIR}/AppIcon.icns"

if [[ "${1:-}" != "--force" && -f "${ICNS_PATH}" ]]; then
    echo "OK ${ICNS_PATH} already exists (pass --force to regenerate)."
    exit 0
fi

mkdir -p "${RES_DIR}"

echo "> Packing ${ICNS_PATH}..."
iconutil -c icns "${ICONSET_DIR}" -o "${ICNS_PATH}"

echo "OK Generated ${ICNS_PATH}"
