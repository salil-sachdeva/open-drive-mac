#!/usr/bin/env zsh
# Builds Open Drive, signs it, and installs it to /Applications/Open Drive.app.
#
# Usage: ./build.sh            release build, install to /Applications
#        ./build.sh --debug    debug build, install to /Applications
#        ./build.sh --open     install, then quit any running copy and open the new one
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_CONFIG="release"
if [[ " $* " == *" --debug "* ]]; then
    BUILD_CONFIG="debug"
fi

BUILD_CONFIG="${BUILD_CONFIG}" "${ROOT_DIR}/Scripts/bundle-app.sh"

SRC_APP="${ROOT_DIR}/dist/Open Drive.app"
DEST_APP="/Applications/Open Drive.app"

echo "==> Installing to ${DEST_APP}..."
rm -rf "${DEST_APP}"
ditto "${SRC_APP}" "${DEST_APP}"
xattr -cr "${DEST_APP}"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "${LSREGISTER}" ]]; then
    "${LSREGISTER}" -f -R -trusted "${DEST_APP}" 2>/dev/null || true
fi

if command -v pluginkit >/dev/null 2>&1; then
    pluginkit -a "${DEST_APP}/Contents/Extensions/OpenDriveFS.appex" 2>/dev/null || true
    pluginkit -a "${DEST_APP}/Contents/PlugIns/OpenDriveFileProvider.appex" 2>/dev/null || true
fi

echo "==> Installed ${DEST_APP}"

if [[ " $* " == *" --open "* ]]; then
    osascript -e 'quit app "Open Drive"' 2>/dev/null || true
    sleep 0.5
    open "${DEST_APP}"
fi
