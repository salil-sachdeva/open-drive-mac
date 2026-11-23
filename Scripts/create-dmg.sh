#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${ROOT_DIR}/dist/Open Drive.app"
DMG_STAGING="${ROOT_DIR}/dist/dmg-staging"
DMG_PATH="${ROOT_DIR}/dist/OpenDrive.dmg"

if [[ "${REUSE_EXISTING_APP:-0}" != "1" || ! -d "${APP_BUNDLE}" ]]; then
    BUILD_CONFIG="${BUILD_CONFIG:-release}" SKIP_LOCAL_OAUTH="${SKIP_LOCAL_OAUTH:-1}" "${ROOT_DIR}/Scripts/bundle-app.sh"
fi

if /usr/bin/plutil -extract OpenDriveGoogleClientSecret raw -o - "${APP_BUNDLE}/Contents/Info.plist" >/dev/null 2>&1; then
    echo "❌ ERROR: OpenDriveGoogleClientSecret is embedded in ${APP_BUNDLE}/Contents/Info.plist." >&2
    echo "❌ Refusing to package a public DMG with private OAuth client secrets inside Info.plist." >&2
    exit 1
fi

echo "==> Preparing DMG staging directory..."
rm -rf "${DMG_STAGING}" "${DMG_PATH}"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/Open Drive.app"
ln -s /Applications "${DMG_STAGING}/Applications"

echo "==> Creating compressed UDIF disk image at ${DMG_PATH}..."
hdiutil create \
    -volname "Open Drive" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

rm -rf "${DMG_STAGING}"
echo "==> Done! DMG created at: ${DMG_PATH}"
