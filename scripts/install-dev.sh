#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# install-dev.sh — the team-signed Xcode build + install path.
#
# This is the build that iCloud sync actually runs in: the CloudKit entitlement
# needs real (team) signing, which only Xcode's automatic signing provides. The
# ad-hoc scripts/bundle.sh + install.sh path stays the zero-cost release build,
# but its CloudKit path is inert. Use this when you want sync.
#
#   ./scripts/install-dev.sh              # build (Release), then install + relaunch
#   ./scripts/install-dev.sh --build-only # build only — no killall/copy/open
#
# --build-only is for CI-less verification and agents that must not disturb a
# running instance. Requires full Xcode (not just the Command Line Tools),
# xcodegen, and a Local.xcconfig with your DEVELOPMENT_TEAM set.

APP_NAME="Recallyx"
APP_BUNDLE="${APP_NAME}.app"
DEST_DIR="${HOME}/Applications"
DERIVED="./.build/xcode"

BUILD_ONLY=0
for arg in "$@"; do
  case "${arg}" in
    --build-only) BUILD_ONLY=1 ;;
    -h|--help)
      echo "Usage: $0 [--build-only]"
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      echo "Usage: $0 [--build-only]" >&2
      exit 2
      ;;
  esac
done

# --- Preflight ---------------------------------------------------------------

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "✗ xcodegen not found. Install it:" >&2
  echo "    brew install xcodegen" >&2
  exit 1
fi

if [ ! -f Local.xcconfig ]; then
  echo "✗ Local.xcconfig not found — Xcode signing needs your team id." >&2
  echo "    cp Local.xcconfig.example Local.xcconfig" >&2
  echo "    # then set DEVELOPMENT_TEAM to your Apple Developer team id" >&2
  echo "  (Local.xcconfig is gitignored — never commit a team id.)" >&2
  exit 1
fi

# Locate a *full* Xcode (the CLT alone can't do automatic team signing). Honor a
# caller-provided DEVELOPER_DIR, else the default install, else Spotlight.
find_developer_dir() {
  if [ -n "${DEVELOPER_DIR:-}" ] && [ -d "${DEVELOPER_DIR}/Platforms/MacOSX.platform" ]; then
    printf '%s\n' "${DEVELOPER_DIR}"
    return 0
  fi
  local candidate="/Applications/Xcode.app/Contents/Developer"
  if [ -d "${candidate}/Platforms/MacOSX.platform" ]; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  local app
  app="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -n 1)"
  if [ -n "${app}" ] && [ -d "${app}/Contents/Developer/Platforms/MacOSX.platform" ]; then
    printf '%s\n' "${app}/Contents/Developer"
    return 0
  fi
  return 1
}

if ! DEV_DIR="$(find_developer_dir)"; then
  echo "✗ Full Xcode not found — this build needs Xcode, not just the Command Line Tools." >&2
  echo "  Install Xcode from the App Store, launch it once to accept the license," >&2
  echo "  then re-run. (The ad-hoc ./scripts/bundle.sh path needs no Xcode.)" >&2
  exit 1
fi

# --- Generate + build --------------------------------------------------------

echo "→ xcodegen generate"
xcodegen generate

echo "→ xcodebuild (Release, team-signed) — DEVELOPER_DIR=${DEV_DIR}"
env DEVELOPER_DIR="${DEV_DIR}" xcodebuild \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -derivedDataPath "${DERIVED}" \
  -allowProvisioningUpdates \
  build

PRODUCT="${DERIVED}/Build/Products/Release/${APP_BUNDLE}"
[ -d "${PRODUCT}" ] || { echo "✗ built app not found at ${PRODUCT}" >&2; exit 1; }

echo "✓ Built ${PRODUCT}"

if [ "${BUILD_ONLY}" -eq 1 ]; then
  echo "→ --build-only: skipping killall / install / launch"
  exit 0
fi

# --- Install + relaunch ------------------------------------------------------

# `open` on a running app with the same bundle ID just foregrounds it — kill any
# existing instance first so the new binary launches. killall's SIGTERM is async,
# so wait (bounded) for the process to exit before continuing, or `open` races
# LaunchServices and returns -600 (procNotFound), dropping the launch.
killall "${APP_NAME}" 2>/dev/null || true
for _ in $(seq 1 30); do
  pgrep -x "${APP_NAME}" >/dev/null 2>&1 || break
  sleep 0.1
done

mkdir -p "${DEST_DIR}"
rm -rf "${DEST_DIR}/${APP_BUNDLE}"
cp -R "${PRODUCT}" "${DEST_DIR}/"

echo "✓ Installed to ${DEST_DIR}/${APP_BUNDLE}"

# LaunchServices can still transiently return -600 right after the kill, so retry
# the launch a few times. Guard each attempt so `set -e` doesn't abort before the
# retries run; only fail if every attempt fails.
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
