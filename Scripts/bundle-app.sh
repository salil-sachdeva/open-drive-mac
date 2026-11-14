#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-/tmp/open-drive-build}"
APP_BUNDLE="${ROOT_DIR}/dist/Open Drive.app"
APPEX_BUNDLE="${APP_BUNDLE}/Contents/Extensions/OpenDriveFS.appex"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/swiftpm-module-cache}"

echo "==> Building OpenDriveApp, OpenDriveFS, and open-drive-mcp..."
swift build --disable-sandbox --package-path "${ROOT_DIR}" --scratch-path "${BUILD_DIR}" -Xswiftc -module-cache-path -Xswiftc /tmp/swift-module-cache

BIN_DIR="$(swift build --disable-sandbox --package-path "${ROOT_DIR}" --scratch-path "${BUILD_DIR}" --show-bin-path)"

echo "==> Assembling Open Drive.app bundle at ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APPEX_BUNDLE}/Contents/MacOS"

cp "${ROOT_DIR}/Config/OpenDriveApp-Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "${BIN_DIR}/OpenDriveApp" "${APP_BUNDLE}/Contents/MacOS/OpenDriveApp"
cp "${BIN_DIR}/open-drive-mcp" "${APP_BUNDLE}/Contents/MacOS/open-drive-mcp"

cp "${ROOT_DIR}/Config/OpenDriveFS-Info.plist" "${APPEX_BUNDLE}/Contents/Info.plist"
cp "${BIN_DIR}/OpenDriveFS" "${APPEX_BUNDLE}/Contents/MacOS/OpenDriveFS"

chmod +x "${APP_BUNDLE}/Contents/MacOS/OpenDriveApp"
chmod +x "${APP_BUNDLE}/Contents/MacOS/open-drive-mcp"
chmod +x "${APPEX_BUNDLE}/Contents/MacOS/OpenDriveFS"

echo "==> Code-signing OpenDriveFS.appex and Open Drive.app (identity: ${CODESIGN_IDENTITY})..."
codesign --force --sign "${CODESIGN_IDENTITY}" \
    --entitlements "${ROOT_DIR}/Config/OpenDriveFS.entitlements" \
    "${APPEX_BUNDLE}"

codesign --force --sign "${CODESIGN_IDENTITY}" \
    "${APP_BUNDLE}/Contents/MacOS/open-drive-mcp"

codesign --force --sign "${CODESIGN_IDENTITY}" \
    --entitlements "${ROOT_DIR}/Config/OpenDriveApp.entitlements" \
    "${APP_BUNDLE}"

if command -v pluginkit >/dev/null 2>&1; then
    pluginkit -a "${APPEX_BUNDLE}" 2>/dev/null || true
fi

echo "==> Done! Signed bundle created at: ${APP_BUNDLE}"
