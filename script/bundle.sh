#!/usr/bin/env bash
#
# Assemble a runnable Recast.app from a SwiftPM build.
#
# Usage:
#   script/bundle.sh [options]
#     --sign <identity>   codesign identity. Default "-" (ad-hoc).
#     --config <cfg>      release (default) or debug.
#     --version <v>       Marketing version stamped into Info.plist.
#                         Defaults to $RECAST_VERSION, then Info.plist.
#     --build <n>         CFBundleVersion (build number). Defaults to Info.plist.
#     --zip               Also produce dist/Recast.zip (ditto, signature-safe).
#
set -euo pipefail

APP_NAME="Recast"
CONFIG="release"
SIGN_IDENTITY="-"
VERSION="${RECAST_VERSION:-}"
BUILD_NUMBER=""
MAKE_ZIP="false"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST_SRC="${REPO_ROOT}/Sources/${APP_NAME}/Info.plist"
DIST_DIR="${REPO_ROOT}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
ZIP_PATH="${DIST_DIR}/${APP_NAME}.zip"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign)    SIGN_IDENTITY="$2"; shift 2 ;;
        --config)  CONFIG="$2";        shift 2 ;;
        --version) VERSION="$2";       shift 2 ;;
        --build)   BUILD_NUMBER="$2";  shift 2 ;;
        --zip)     MAKE_ZIP="true";    shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${VERSION}" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST_SRC}")"
fi
VERSION="${VERSION#v}"
if [[ -z "${BUILD_NUMBER}" ]]; then
    BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST_SRC}")"
fi

if [[ "${CONFIG}" != "debug" && "${CONFIG}" != "release" ]]; then
    echo "ERROR --config must be 'debug' or 'release'" >&2
    exit 1
fi

echo "> Building ${APP_NAME} ${VERSION} (${CONFIG})..."
swift build --configuration "${CONFIG}" --package-path "${REPO_ROOT}"

BIN_DIR="$(swift build --configuration "${CONFIG}" --package-path "${REPO_ROOT}" --show-bin-path)"
EXECUTABLE="${BIN_DIR}/${APP_NAME}"

if [[ ! -x "${EXECUTABLE}" ]]; then
    echo "ERROR Executable not found at ${EXECUTABLE}" >&2
    exit 1
fi

echo "> Assembling ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${EXECUTABLE}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "${INFO_PLIST_SRC}" "${APP_DIR}/Contents/Info.plist"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
    "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" \
    "${APP_DIR}/Contents/Info.plist"

if [[ -f "${REPO_ROOT}/Resources/AppIcon.icns" ]]; then
    cp "${REPO_ROOT}/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" \
        "${APP_DIR}/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
        "${APP_DIR}/Contents/Info.plist"
fi

# App finds Sparkle.framework via the @executable_path/../Frameworks rpath in Package.swift.
FRAMEWORK_SRC="${BIN_DIR}/Sparkle.framework"
if [[ ! -d "${FRAMEWORK_SRC}" ]]; then
    echo "ERROR Sparkle.framework not found at ${FRAMEWORK_SRC}" >&2
    exit 1
fi
echo "> Embedding Sparkle.framework..."
mkdir -p "${APP_DIR}/Contents/Frameworks"
cp -R "${FRAMEWORK_SRC}" "${APP_DIR}/Contents/Frameworks/"

echo "> Signing with identity: ${SIGN_IDENTITY}"
SIGN_ARGS=(--force --sign "${SIGN_IDENTITY}")
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    SIGN_ARGS+=(--timestamp=none)
else
    SIGN_ARGS+=(--options runtime --timestamp)
fi

# Sparkle's nested helpers must be signed inside-out, deepest first, or the outer signature is rejected.
echo "> Signing Sparkle's nested helpers..."
FRAMEWORK="${APP_DIR}/Contents/Frameworks/Sparkle.framework"
VERSIONED="${FRAMEWORK}/Versions/Current"
for nested in \
    "${VERSIONED}/XPCServices/Downloader.xpc" \
    "${VERSIONED}/XPCServices/Installer.xpc" \
    "${VERSIONED}/Autoupdate" \
    "${VERSIONED}/Updater.app"; do
    codesign "${SIGN_ARGS[@]}" "${nested}"
done
codesign "${SIGN_ARGS[@]}" "${FRAMEWORK}"
codesign "${SIGN_ARGS[@]}" "${APP_DIR}"

echo "> Verifying signature..."
codesign --verify --strict --verbose=2 "${APP_DIR}"

if [[ "${MAKE_ZIP}" == "true" ]]; then
    echo "> Creating ${ZIP_PATH}..."
    rm -f "${ZIP_PATH}"
    /usr/bin/ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"
fi

echo ""
echo "OK Built ${APP_DIR} (v${VERSION}, build ${BUILD_NUMBER})"
[[ "${MAKE_ZIP}" == "true" ]] && echo "OK Zipped ${ZIP_PATH}"
echo "  Run it with:  open \"${APP_DIR}\""
