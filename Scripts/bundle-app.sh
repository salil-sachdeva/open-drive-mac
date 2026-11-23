#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRIVATE_TMP_BASE="${TMPDIR:-/tmp}"
PRIVATE_TMP_BASE="${PRIVATE_TMP_BASE%/}"
PRIVATE_TMP="${PRIVATE_TMP_BASE}/open-drive-build-${UID}"
mkdir -p -m 700 "${PRIVATE_TMP}" "${PRIVATE_TMP}/clang-module-cache" "${PRIVATE_TMP}/swiftpm-module-cache" "${PRIVATE_TMP}/swift-module-cache"
BUILD_DIR="${BUILD_DIR:-${PRIVATE_TMP}/build}"
mkdir -p -m 700 "${BUILD_DIR}"
BUILD_CONFIG="${BUILD_CONFIG:-debug}"
SWIFTPM_BUILD_SYSTEM="${SWIFTPM_BUILD_SYSTEM:-native}"
APP_BUNDLE="${ROOT_DIR}/dist/Open Drive.app"
APPEX_BUNDLE="${APP_BUNDLE}/Contents/Extensions/OpenDriveFS.appex"
FP_APPEX_BUNDLE="${APP_BUNDLE}/Contents/PlugIns/OpenDriveFileProvider.appex"

# Auto-detect "Apple Development" certificate if CODESIGN_IDENTITY / SIGN_IDENTITY is unset;
# fall back to ad-hoc signing ("-").
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-${SIGN_IDENTITY:-}}"
if [[ -z "${CODESIGN_IDENTITY}" ]]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)"
fi
[[ -n "${CODESIGN_IDENTITY}" ]] || CODESIGN_IDENTITY="-"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${PRIVATE_TMP}/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-${PRIVATE_TMP}/swiftpm-module-cache}"
SWIFT_MODULE_CACHE="${PRIVATE_TMP}/swift-module-cache"

# Load gitignored build-time Google OAuth credentials without overriding non-empty caller env vars.
CALLER_GOOGLE_CLIENT_ID="${OPENDRIVE_GOOGLE_CLIENT_ID:-}"
CALLER_GOOGLE_CLIENT_SECRET="${OPENDRIVE_GOOGLE_CLIENT_SECRET:-}"
if [[ "${SKIP_LOCAL_OAUTH:-0}" != "1" && -f "${ROOT_DIR}/Config/OAuth.local.env" ]]; then
    set -a
    source "${ROOT_DIR}/Config/OAuth.local.env"
    set +a
fi
if [[ -n "${CALLER_GOOGLE_CLIENT_ID}" ]]; then
    OPENDRIVE_GOOGLE_CLIENT_ID="${CALLER_GOOGLE_CLIENT_ID}"
fi
if [[ -n "${CALLER_GOOGLE_CLIENT_SECRET}" ]]; then
    OPENDRIVE_GOOGLE_CLIENT_SECRET="${CALLER_GOOGLE_CLIENT_SECRET}"
fi
OPENDRIVE_GOOGLE_CLIENT_ID="${OPENDRIVE_GOOGLE_CLIENT_ID:-}"
OPENDRIVE_GOOGLE_CLIENT_SECRET="${OPENDRIVE_GOOGLE_CLIENT_SECRET:-}"

echo "==> Building OpenDriveApp, OpenDriveFS, and OpenDriveFileProvider (${BUILD_CONFIG})..."
swift build -c "${BUILD_CONFIG}" --build-system "${SWIFTPM_BUILD_SYSTEM}" --disable-sandbox --package-path "${ROOT_DIR}" --scratch-path "${BUILD_DIR}" -Xswiftc -module-cache-path -Xswiftc "${SWIFT_MODULE_CACHE}"

BIN_DIR="$(swift build -c "${BUILD_CONFIG}" --build-system "${SWIFTPM_BUILD_SYSTEM}" --disable-sandbox --package-path "${ROOT_DIR}" --scratch-path "${BUILD_DIR}" --show-bin-path)"

echo "==> Assembling Open Drive.app bundle at ${APP_BUNDLE}..."
if [[ -d "${ROOT_DIR}/Icon/AppIcon.icon" ]]; then
    if [[ ! -f "${ROOT_DIR}/Resources/Assets.car" || ! -f "${ROOT_DIR}/Resources/AppIcon.icns" || -n "$(find "${ROOT_DIR}/Icon/AppIcon.icon" -newer "${ROOT_DIR}/Resources/Assets.car" 2>/dev/null)" ]]; then
        echo "==> Compiling Icon/AppIcon.icon..."
        "${ROOT_DIR}/tools/make_icon.sh"
    fi
fi

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APPEX_BUNDLE}/Contents/MacOS"
mkdir -p "${FP_APPEX_BUNDLE}/Contents/MacOS"

cp "${ROOT_DIR}/Config/OpenDriveApp-Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "${BIN_DIR}/OpenDriveApp" "${APP_BUNDLE}/Contents/MacOS/OpenDriveApp"
if [[ -f "${ROOT_DIR}/Resources/Assets.car" ]]; then
    cp "${ROOT_DIR}/Resources/Assets.car" "${APP_BUNDLE}/Contents/Resources/Assets.car"
fi
if [[ -f "${ROOT_DIR}/Resources/AppIcon.icns" ]]; then
    cp "${ROOT_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

cp "${ROOT_DIR}/Config/OpenDriveFS-Info.plist" "${APPEX_BUNDLE}/Contents/Info.plist"
cp "${BIN_DIR}/OpenDriveFS" "${APPEX_BUNDLE}/Contents/MacOS/OpenDriveFS"

cp "${ROOT_DIR}/Config/OpenDriveFileProvider-Info.plist" "${FP_APPEX_BUNDLE}/Contents/Info.plist"
ARCH="$(uname -m)"
SDK_PATH="$(xcrun --show-sdk-path)"
FP_OPT_FLAGS=("-Onone" "-g")
if [[ "${BUILD_CONFIG}" == "release" ]]; then
    FP_OPT_FLAGS=("-O")
fi
echo "==> Linking OpenDriveFileProvider.appex binary (-e _NSExtensionMain, ${BUILD_CONFIG})..."
xcrun swiftc \
    "${FP_OPT_FLAGS[@]}" \
    -swift-version 5 \
    -module-name OpenDriveFileProvider \
    -parse-as-library \
    -application-extension \
    -sdk "${SDK_PATH}" \
    -target "${ARCH}-apple-macosx15.4" \
    -module-cache-path "${SWIFT_MODULE_CACHE}" \
    -framework FileProvider \
    -framework Foundation \
    -framework UniformTypeIdentifiers \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -Xlinker -u -Xlinker _OBJC_CLASS_\$_OpenDriveFileProviderExtension \
    "${ROOT_DIR}/Sources/OpenDriveFileProvider/OpenDriveFileProviderExtension.swift" \
    -o "${FP_APPEX_BUNDLE}/Contents/MacOS/OpenDriveFileProvider"

if [[ -n "${OPENDRIVE_GOOGLE_CLIENT_ID}" ]]; then
    for plist_path in "${APP_BUNDLE}/Contents/Info.plist" "${APPEX_BUNDLE}/Contents/Info.plist"; do
        /usr/bin/plutil -replace OpenDriveGoogleClientID -string "${OPENDRIVE_GOOGLE_CLIENT_ID}" "${plist_path}"
        if [[ -n "${OPENDRIVE_GOOGLE_CLIENT_SECRET}" ]]; then
            /usr/bin/plutil -replace OpenDriveGoogleClientSecret -string "${OPENDRIVE_GOOGLE_CLIENT_SECRET}" "${plist_path}"
        fi
    done
fi

chmod +x "${APP_BUNDLE}/Contents/MacOS/OpenDriveApp"
chmod +x "${APPEX_BUNDLE}/Contents/MacOS/OpenDriveFS"
chmod +x "${FP_APPEX_BUNDLE}/Contents/MacOS/OpenDriveFileProvider"

APP_ENTITLEMENTS="${ROOT_DIR}/Config/OpenDriveApp.entitlements"
if [[ -n "${APP_PROVISIONING_PROFILE:-}" && -f "${APP_PROVISIONING_PROFILE}" ]]; then
    cp "${APP_PROVISIONING_PROFILE}" "${APP_BUNDLE}/Contents/embedded.provisionprofile"
    APP_ENTITLEMENTS="${ROOT_DIR}/Config/OpenDriveApp-Provisioned.entitlements"
fi

FS_ENTITLEMENTS="${ROOT_DIR}/Config/OpenDriveFS.entitlements"
if [[ -n "${FS_PROVISIONING_PROFILE:-}" && -f "${FS_PROVISIONING_PROFILE}" ]]; then
    cp "${FS_PROVISIONING_PROFILE}" "${APPEX_BUNDLE}/Contents/embedded.provisionprofile"
    FS_ENTITLEMENTS="${ROOT_DIR}/Config/OpenDriveFS-Provisioned.entitlements"
fi

FP_ENTITLEMENTS="${ROOT_DIR}/Config/OpenDriveFileProvider.entitlements"

xattr -cr "${APP_BUNDLE}"

CODESIGN_OPTS=()
if [[ "${CODESIGN_IDENTITY}" != "-" ]]; then
    CODESIGN_OPTS=(--options runtime)
fi

echo "==> Code-signing OpenDriveFS.appex, OpenDriveFileProvider.appex, and Open Drive.app (identity: ${CODESIGN_IDENTITY})..."
codesign --force "${CODESIGN_OPTS[@]}" --sign "${CODESIGN_IDENTITY}" \
    --entitlements "${FS_ENTITLEMENTS}" \
    "${APPEX_BUNDLE}"

codesign --force "${CODESIGN_OPTS[@]}" --sign "${CODESIGN_IDENTITY}" \
    --entitlements "${FP_ENTITLEMENTS}" \
    "${FP_APPEX_BUNDLE}"

codesign --force "${CODESIGN_OPTS[@]}" --sign "${CODESIGN_IDENTITY}" \
    --entitlements "${APP_ENTITLEMENTS}" \
    "${APP_BUNDLE}"

if command -v pluginkit >/dev/null 2>&1; then
    pluginkit -a "${APPEX_BUNDLE}" 2>/dev/null || true
    pluginkit -a "${FP_APPEX_BUNDLE}" 2>/dev/null || true
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "${LSREGISTER}" ]]; then
    "${LSREGISTER}" -f -R -trusted "${APP_BUNDLE}" 2>/dev/null || true
fi

echo "==> Done! Signed bundle created at: ${APP_BUNDLE}"
