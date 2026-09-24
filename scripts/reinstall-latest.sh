#!/usr/bin/env bash
# One-shot reinstall: quit Recallyx, reset its Accessibility grant, download the
# latest release DMG from GitHub, replace the installed app, clear quarantine,
# and relaunch. Meant to be piped straight from GitHub:
#
#   curl -fsSL https://raw.githubusercontent.com/macrosak/recallyx/main/scripts/reinstall-latest.sh | bash
#
# Options (pass after `bash -s --` when piping):
#   --no-reset          keep the current Accessibility grant (skip tccutil)
#   --dest <dir>        install into <dir> (default: wherever Recallyx.app is
#                       already installed, else /Applications)
#
# Why the reset: release DMGs are ad-hoc signed, so every new version has a new
# code signature. macOS keeps the old Accessibility entry, which no longer
# matches, and ⌃⇧V fails with "Accessibility permission missing" even though
# the toggle looks on. Removing the stale entry and granting it again fixes it.
set -euo pipefail

REPO="macrosak/recallyx"
BUNDLE_ID="io.github.macrosak.recallyx"
APP="Recallyx.app"

RESET=1
DEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-reset) RESET=0 ;;
    --dest) DEST="${2:?--dest needs a directory}"; shift ;;
    -h|--help) sed -n '2,17p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '→ %s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Recallyx is a macOS app — run this on a Mac."
[ "$(uname -m)" = "arm64" ] || die "Release builds are Apple Silicon (arm64) only."

# Pick the install location: an explicit --dest, else wherever it's installed
# now (install.sh uses ~/Applications, the DMG instructions use /Applications).
if [ -z "${DEST}" ]; then
  if [ -d "/Applications/${APP}" ]; then
    DEST="/Applications"
  elif [ -d "${HOME}/Applications/${APP}" ]; then
    DEST="${HOME}/Applications"
  else
    DEST="/Applications"
  fi
fi
if [ -d "/Applications/${APP}" ] && [ -d "${HOME}/Applications/${APP}" ]; then
  echo "! Recallyx is installed in both /Applications and ~/Applications."
  echo "  Updating ${DEST}. Delete the other copy so the old one can't be launched by mistake."
fi

WORK="$(mktemp -d)"
MOUNT="${WORK}/mnt"
cleanup() {
  hdiutil detach "${MOUNT}" -quiet 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

say "Looking up the latest release"
RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")" \
  || die "Couldn't reach the GitHub API."
DMG_URL="$(printf '%s' "${RELEASE_JSON}" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -n1 | sed 's/.*"\(https[^"]*\)"$/\1/')"
TAG="$(printf '%s' "${RELEASE_JSON}" | grep -o '"tag_name": *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
[ -n "${DMG_URL}" ] || die "The latest release has no DMG asset."

say "Downloading Recallyx ${TAG}"
curl -fL --progress-bar -o "${WORK}/Recallyx.dmg" "${DMG_URL}" || die "Download failed."

say "Quitting Recallyx"
osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  pgrep -x Recallyx >/dev/null 2>&1 || break
  sleep 0.1
done
killall Recallyx 2>/dev/null || true
for _ in $(seq 1 30); do
  pgrep -x Recallyx >/dev/null 2>&1 || break
  sleep 0.1
done

if [ "${RESET}" -eq 1 ]; then
  say "Resetting the Accessibility permission"
  tccutil reset Accessibility "${BUNDLE_ID}" >/dev/null \
    || echo "! tccutil reset failed — reset it by hand in System Settings → Privacy & Security → Accessibility."
fi

say "Installing to ${DEST}/${APP}"
mkdir -p "${WORK}/mnt"
hdiutil attach "${WORK}/Recallyx.dmg" -nobrowse -readonly -quiet -mountpoint "${MOUNT}" \
  || die "Couldn't open the DMG."
[ -d "${MOUNT}/${APP}" ] || die "The DMG doesn't contain ${APP}."

SUDO=""
mkdir -p "${DEST}" 2>/dev/null || true
if [ ! -w "${DEST}" ] || { [ -e "${DEST}/${APP}" ] && [ ! -w "${DEST}/${APP}" ]; }; then
  echo "  ${DEST} isn't writable by you — asking for your password."
  SUDO="sudo"
fi
${SUDO} rm -rf "${DEST}/${APP}"
${SUDO} ditto "${MOUNT}/${APP}" "${DEST}/${APP}"
# The download is quarantined; the build isn't notarized, so Gatekeeper would block it.
${SUDO} xattr -dr com.apple.quarantine "${DEST}/${APP}" 2>/dev/null || true

say "Launching Recallyx"
for attempt in 1 2 3; do
  open "${DEST}/${APP}" && break
  [ "${attempt}" -eq 3 ] && die "Couldn't launch ${DEST}/${APP}."
  sleep 0.5
done

echo "✓ Recallyx ${TAG} installed at ${DEST}/${APP}"
if [ "${RESET}" -eq 1 ]; then
  cat <<'MSG'

Next, grant Accessibility again (⌃⇧V and pasting need it):
  1. Press ⌃⇧V (or paste a clip). macOS asks for Accessibility access.
  2. Turn Recallyx on in System Settings → Privacy & Security → Accessibility.
  3. Quit Recallyx from its menu-bar icon and open it again. macOS only picks up
     the permission when the app starts.
MSG
fi
