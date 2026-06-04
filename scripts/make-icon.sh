#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="${1:-Sources/Recallyx/Resources/icon.png}"
DEST="${2:-Sources/Recallyx/Resources/AppIcon.icns}"

[ -f "${SRC}" ] || { echo "Source icon not found at ${SRC}"; exit 1; }

TMP="$(mktemp -d)"
ICONSET="${TMP}/AppIcon.iconset"
mkdir -p "${ICONSET}"

sips -z 16 16     "${SRC}" --out "${ICONSET}/icon_16x16.png"       > /dev/null
sips -z 32 32     "${SRC}" --out "${ICONSET}/icon_16x16@2x.png"    > /dev/null
sips -z 32 32     "${SRC}" --out "${ICONSET}/icon_32x32.png"       > /dev/null
sips -z 64 64     "${SRC}" --out "${ICONSET}/icon_32x32@2x.png"    > /dev/null
sips -z 128 128   "${SRC}" --out "${ICONSET}/icon_128x128.png"     > /dev/null
sips -z 256 256   "${SRC}" --out "${ICONSET}/icon_128x128@2x.png"  > /dev/null
sips -z 256 256   "${SRC}" --out "${ICONSET}/icon_256x256.png"     > /dev/null
sips -z 512 512   "${SRC}" --out "${ICONSET}/icon_256x256@2x.png"  > /dev/null
sips -z 512 512   "${SRC}" --out "${ICONSET}/icon_512x512.png"     > /dev/null
sips -z 1024 1024 "${SRC}" --out "${ICONSET}/icon_512x512@2x.png"  > /dev/null

mkdir -p "$(dirname "${DEST}")"
iconutil -c icns -o "${DEST}" "${ICONSET}"
rm -rf "${TMP}"

echo "✓ Wrote ${DEST}"
