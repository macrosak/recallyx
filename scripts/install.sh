#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_BUNDLE="Recallyx.app"
DEST_DIR="${HOME}/Applications"

[ -d "${APP_BUNDLE}" ] || { echo "${APP_BUNDLE} not found — run scripts/bundle.sh first"; exit 1; }

# `open` on a running app with the same bundle ID just foregrounds it — kill any
# existing instance first so the new binary actually launches. killall's SIGTERM
# is async, so wait for the process to actually exit before continuing: if `open`
# fires while the old instance is still registered with LaunchServices it returns
# -600 (procNotFound) and silently drops the launch. Bound the wait (~3s) so a
# stuck process can't deadlock us.
killall Recallyx 2>/dev/null || true
for _ in $(seq 1 30); do
  pgrep -x Recallyx >/dev/null 2>&1 || break
  sleep 0.1
done

mkdir -p "${DEST_DIR}"
rm -rf "${DEST_DIR}/${APP_BUNDLE}"
cp -R "${APP_BUNDLE}" "${DEST_DIR}/"

echo "✓ Installed to ${DEST_DIR}/${APP_BUNDLE}"

# LaunchServices can still transiently return -600 right after the kill, so retry
# the launch a few times. Guard each attempt so `set -e` doesn't abort before the
# retries run; only fail the script if every attempt fails.
for attempt in 1 2 3; do
  if open "${DEST_DIR}/${APP_BUNDLE}"; then
    break
  fi
  if [ "${attempt}" -eq 3 ]; then
    echo "Failed to launch ${APP_BUNDLE} after ${attempt} attempts" >&2
    exit 1
  fi
  sleep 0.5
done
