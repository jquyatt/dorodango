#!/usr/bin/env bash
# Builds Dorodango.app from the SwiftPM executable + Info.plist.
# Requires: Xcode command line tools (swift) and macOS 13+.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Dorodango"
BUILD_CONFIG="${1:-release}"   # pass "debug" for a faster, unoptimized build

echo "==> Building (${BUILD_CONFIG})..."
swift build -c "${BUILD_CONFIG}"

BIN_PATH="$(swift build -c "${BUILD_CONFIG}" --show-bin-path)/${APP_NAME}"
APP_DIR="build/${APP_NAME}.app"

echo "==> Assembling ${APP_DIR} ..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

# Generate the app icon from Icon.png (if present) using macOS tools.
ICON_SRC="dorodango_icon.png"
if [[ -f "${ICON_SRC}" ]] && command -v sips >/dev/null && command -v iconutil >/dev/null; then
  echo "==> Generating app icon from ${ICON_SRC} ..."
  ICONSET="build/AppIcon.iconset"
  rm -rf "${ICONSET}"; mkdir -p "${ICONSET}"
  for s in 16 32 128 256 512; do
    sips -z "${s}" "${s}" "${ICON_SRC}" --out "${ICONSET}/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "${d}" "${d}" "${ICON_SRC}" --out "${ICONSET}/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "${ICONSET}" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"
else
  echo "   (no Icon.png, or sips/iconutil missing — skipping app icon)"
fi

# Ad-hoc code signature so macOS will run it locally.
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || \
  echo "   (codesign skipped -- app will still run after right-click > Open)"

echo "==> Done: ${APP_DIR}"
echo "    Run it with:  open \"${APP_DIR}\""
echo "    Or move it to /Applications."
