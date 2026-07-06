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
#   ./scripts/install-dev.sh --ck-dev     # build against CloudKit DEVELOPMENT instead
#                                         # of Production — see below
#
# --build-only is for CI-less verification and agents that must not disturb a
# running instance. Requires full Xcode (not just the Command Line Tools),
# xcodegen, and a Local.xcconfig with your DEVELOPMENT_TEAM set.
#
# --ck-dev: the CloudKit Production schema never auto-evolves, and every build
# now targets Production (see CLAUDE.md) — so adding a synced model field (a new
# ClipEntity attribute) silently breaks Production sync (CKError 2 /
# partialFailure) until the field exists in the Development schema too. This
# flag temporarily flips com.apple.developer.icloud-container-environment to
# Development in Recallyx.entitlements, builds+installs, then restores the
# entitlements file byte-for-byte (trap, like testflight.sh's Info.plist stamp)
# so the working tree stays clean either way. Run it once, copy something to
# create the new field in the Development schema, then in CloudKit Console:
# Deploy Schema Changes to Production — then rebuild WITHOUT --ck-dev. Combine
# with --build-only freely; the swap+restore wraps the same build either way.

APP_NAME="Recallyx"
APP_BUNDLE="${APP_NAME}.app"
DEST_DIR="${HOME}/Applications"
DERIVED="./.build/xcode"
ENTITLEMENTS="Sources/Recallyx/Resources/Recallyx.entitlements"

BUILD_ONLY=0
CK_DEV=0
for arg in "$@"; do
  case "${arg}" in
    --build-only) BUILD_ONLY=1 ;;
    --ck-dev) CK_DEV=1 ;;
    -h|--help)
      echo "Usage: $0 [--build-only] [--ck-dev]"
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      echo "Usage: $0 [--build-only] [--ck-dev]" >&2
      exit 2
      ;;
  esac
done

print_ck_dev_banner() {
  echo "" >&2
  echo "############################################################" >&2
  echo "#  --ck-dev: this build talks to the CloudKit DEVELOPMENT   #" >&2
  echo "#  environment, not Production.                            #" >&2
  echo "#                                                           #" >&2
  echo "#  Use it to create new schema fields: launch it, copy      #" >&2
  echo "#  something (so the new field round-trips), then in       #" >&2
  echo "#  CloudKit Console: Deploy Schema Changes to Production.   #" >&2
  echo "#  Then rebuild WITHOUT --ck-dev before daily use.          #" >&2
  echo "############################################################" >&2
  echo "" >&2
}

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

# --- Optional CloudKit Development swap (--ck-dev) ---------------------------

# Temporarily flip the entitlements' CloudKit environment to Development for
# this build, then ALWAYS restore the original file byte-for-byte — even on
# failure — via an EXIT trap, mirroring testflight.sh's Info.plist stamp.
if [ "${CK_DEV}" -eq 1 ]; then
  if [ ! -f "${ENTITLEMENTS}" ]; then
    echo "✗ Entitlements file not found at ${ENTITLEMENTS}" >&2
    exit 1
  fi

  ENTITLEMENTS_BACKUP="$(mktemp)"
  cp "${ENTITLEMENTS}" "${ENTITLEMENTS_BACKUP}"
  restore_entitlements() {
    cp "${ENTITLEMENTS_BACKUP}" "${ENTITLEMENTS}"
    rm -f "${ENTITLEMENTS_BACKUP}"
  }
  trap restore_entitlements EXIT

  echo "→ --ck-dev: swapping ${ENTITLEMENTS} to the Development CloudKit environment (restored after)"
  /usr/libexec/PlistBuddy -c \
    "Set :com.apple.developer.icloud-container-environment Development" \
    "${ENTITLEMENTS}"

  print_ck_dev_banner
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

if [ "${CK_DEV}" -eq 1 ]; then
  print_ck_dev_banner
fi

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
