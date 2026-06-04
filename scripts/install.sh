#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_BUNDLE="Recallyx.app"
DEST_DIR="${HOME}/Applications"

[ -d "${APP_BUNDLE}" ] || { echo "${APP_BUNDLE} not found — run scripts/bundle.sh first"; exit 1; }

# `open` on a running app with the same bundle ID just foregrounds it — kill any
# existing instance first so the new binary actually launches.
killall Recallyx 2>/dev/null || true

mkdir -p "${DEST_DIR}"
rm -rf "${DEST_DIR}/${APP_BUNDLE}"
cp -R "${APP_BUNDLE}" "${DEST_DIR}/"

echo "✓ Installed to ${DEST_DIR}/${APP_BUNDLE}"
open "${DEST_DIR}/${APP_BUNDLE}"
