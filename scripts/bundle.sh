#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Recallyx"
APP_BUNDLE="${APP_NAME}.app"

echo "→ swift build -c release --arch arm64"
swift build -c release --arch arm64

EXEC_PATH=".build/release/${APP_NAME}"
[ -f "${EXEC_PATH}" ] || { echo "executable not found at ${EXEC_PATH}"; exit 1; }

echo "→ Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "${EXEC_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Sources/Recallyx/Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
if [ -f Sources/Recallyx/Resources/AppIcon.icns ]; then
    cp Sources/Recallyx/Resources/AppIcon.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

SIGN_IDENTITY="${RECALLYX_SIGN_IDENTITY:-Recallyx Dev}"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "${SIGN_IDENTITY}"; then
    echo "→ Codesign with \"${SIGN_IDENTITY}\""
    codesign --force --deep --sign "${SIGN_IDENTITY}" --options runtime "${APP_BUNDLE}"
else
    echo "→ Codesign (ad-hoc fallback — run scripts/create-signing-identity.sh"
    echo "  for a stable identity that survives rebuilds in TCC)"
    codesign --force --deep --sign - --options runtime "${APP_BUNDLE}"
fi

echo "✓ Built ${APP_BUNDLE}"
