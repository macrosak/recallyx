#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# testflight.sh — archive the iOS companion app and upload it to TestFlight.
#
# One command for the whole flow: stamp a fresh build number, xcodegen generate,
# xcodebuild archive (generic iOS), then xcodebuild -exportArchive with an
# app-store-connect / upload ExportOptions.plist. This is the manual flow that
# was verified working on this machine, wrapped up.
#
#   ./scripts/testflight.sh                 # archive + upload to TestFlight
#   ./scripts/testflight.sh --archive-only  # archive only — skip the upload
#                                           # (verify the build without spamming TestFlight)
#
# Requires full Xcode (not just the Command Line Tools), xcodegen, a paid Apple
# Developer team, an Apple ID signed into Xcode (Settings → Accounts), and a
# gitignored Local.xcconfig with your DEVELOPMENT_TEAM set.
#
# Build number: App Store Connect rejects a duplicate CFBundleVersion, so we
# stamp the iOS Info.plist's CFBundleVersion with the repo's commit-count version
# (git rev-list HEAD --first-parent --count) before archiving, then ALWAYS restore
# the file so the working tree stays clean. Override with RECALLYX_BUILD_NUMBER.

APP_NAME="Recallyx"
IOS_SCHEME="RecallyxiOS"
INFO_PLIST="Sources/RecallyxiOS/Resources/Info.plist"
ARCHIVE_PATH=".build/${IOS_SCHEME}.xcarchive"
EXPORT_PATH=".build/export"
EXPORT_OPTIONS=".build/ExportOptions.plist"

ARCHIVE_ONLY=0
for arg in "$@"; do
  case "${arg}" in
    --archive-only) ARCHIVE_ONLY=1 ;;
    -h|--help)
      echo "Usage: $0 [--archive-only]"
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      echo "Usage: $0 [--archive-only]" >&2
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
  echo "✗ Local.xcconfig not found — signing/upload needs your team id." >&2
  echo "    cp Local.xcconfig.example Local.xcconfig" >&2
  echo "    # then set DEVELOPMENT_TEAM to your Apple Developer team id" >&2
  echo "  (Local.xcconfig is gitignored — never commit a team id.)" >&2
  exit 1
fi

# Extract DEVELOPMENT_TEAM from Local.xcconfig. Anchor on a real assignment line
# (^ … DEVELOPMENT_TEAM =) — a naive `grep DEVELOPMENT_TEAM` also matches the
# example file's comment line ("// Then set DEVELOPMENT_TEAM to …") and would
# pull garbage. Strip any inline // comment and surrounding whitespace.
TEAM_LINE="$(grep -E '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=' Local.xcconfig | head -n1 || true)"
TEAM_ID="${TEAM_LINE#*=}"      # value after the first =
TEAM_ID="${TEAM_ID%%//*}"      # drop any inline // comment (xcconfig comment syntax)
TEAM_ID="$(printf '%s' "${TEAM_ID}" | tr -d '[:space:]')"

if [ -z "${TEAM_ID}" ] || ! printf '%s' "${TEAM_ID}" | grep -qE '^[A-Z0-9]+$'; then
  echo "✗ DEVELOPMENT_TEAM in Local.xcconfig looks unset or invalid." >&2
  echo "  Set it to your Apple Developer team id (e.g. DEVELOPMENT_TEAM = ABCDE12345)." >&2
  exit 1
fi

# Locate a *full* Xcode (the CLT alone can't archive/upload). Honor a
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
  echo "✗ Full Xcode not found — archiving/uploading needs Xcode, not just the Command Line Tools." >&2
  echo "  Install Xcode from the App Store, launch it once to accept the license, then re-run." >&2
  exit 1
fi

# --- Build number stamping ---------------------------------------------------

BUILD_NUMBER="${RECALLYX_BUILD_NUMBER:-$(git rev-list HEAD --first-parent --count)}"

if [ ! -f "${INFO_PLIST}" ]; then
  echo "✗ iOS Info.plist not found at ${INFO_PLIST}" >&2
  exit 1
fi

# Stamp CFBundleVersion, but ALWAYS restore the original file — even on failure —
# so the working tree stays clean. Back up the exact bytes and cp them back in an
# EXIT trap (a byte-for-byte restore, not a re-edit).
PLIST_BACKUP="$(mktemp)"
cp "${INFO_PLIST}" "${PLIST_BACKUP}"
restore_plist() {
  cp "${PLIST_BACKUP}" "${INFO_PLIST}"
  rm -f "${PLIST_BACKUP}"
}
trap restore_plist EXIT

echo "→ Stamping CFBundleVersion = ${BUILD_NUMBER} in ${INFO_PLIST} (restored after)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${INFO_PLIST}"

# --- Generate + archive ------------------------------------------------------

echo "→ xcodegen generate"
xcodegen generate

echo "→ xcodebuild archive (${IOS_SCHEME}, generic/iOS) — DEVELOPER_DIR=${DEV_DIR}"
env DEVELOPER_DIR="${DEV_DIR}" xcodebuild \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${IOS_SCHEME}" \
  -destination 'generic/platform=iOS' \
  -archivePath "${ARCHIVE_PATH}" \
  archive \
  -allowProvisioningUpdates

[ -d "${ARCHIVE_PATH}" ] || { echo "✗ archive not found at ${ARCHIVE_PATH}" >&2; exit 1; }
echo "✓ Archived ${ARCHIVE_PATH} (build ${BUILD_NUMBER})"

if [ "${ARCHIVE_ONLY}" -eq 1 ]; then
  echo "→ --archive-only: skipping the TestFlight upload"
  echo "✓ Done. Archive is at ${ARCHIVE_PATH}, stamped build ${BUILD_NUMBER}."
  exit 0
fi

# --- Export + upload to TestFlight -------------------------------------------

echo "→ Writing ${EXPORT_OPTIONS}"
mkdir -p "$(dirname "${EXPORT_OPTIONS}")"
cat > "${EXPORT_OPTIONS}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST

echo "→ xcodebuild -exportArchive (upload to App Store Connect)"
EXPORT_LOG="$(mktemp)"
if ! env DEVELOPER_DIR="${DEV_DIR}" xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -exportPath "${EXPORT_PATH}" \
  -allowProvisioningUpdates 2>&1 | tee "${EXPORT_LOG}"; then
  # The most common failure is the Xcode account not being signed in / usable.
  if grep -q "Failed to Use Accounts" "${EXPORT_LOG}"; then
    echo "" >&2
    echo "✗ Upload failed: Xcode couldn't use your developer account." >&2
    echo "  Sign into Xcode → Settings → Accounts (and fully restart Xcode once)," >&2
    echo "  then re-run." >&2
  fi
  rm -f "${EXPORT_LOG}"
  exit 1
fi
rm -f "${EXPORT_LOG}"

echo ""
echo "✓ Uploaded build ${BUILD_NUMBER} to App Store Connect."
echo "  Check App Store Connect → TestFlight (processing ~5-15 min)."
