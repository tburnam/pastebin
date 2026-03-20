#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PasteBin"
BUNDLE_ID="com.tylerburnam.pastebin"
ICON_PNG="pastebinicon.png"
MINIMUM_SYSTEM_VERSION="14.0"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
CREATE_DMG_RETRIES="${CREATE_DMG_RETRIES:-20}"
DIST_DIR="dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"
ICON_ICNS="${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
STATUS_BAR_SOURCE_PNG="${APP_BUNDLE}/Contents/Resources/StatusBarSource.png"
ZIP_PATH="${DIST_DIR}/${APP_NAME}.app.zip"
LATEST_DMG_PATH="${DIST_DIR}/${APP_NAME}-latest.dmg"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

find_latest_build() {
  local latest_path=""
  local latest_mtime="0"
  local candidate
  local mtime

  while IFS= read -r candidate; do
    [ -x "$candidate" ] || continue
    mtime="$(stat -f '%m' "$candidate")"
    if [ -z "$latest_path" ] || [ "$mtime" -gt "$latest_mtime" ]; then
      latest_path="$candidate"
      latest_mtime="$mtime"
    fi
  done < <(find .build -type f -path "*/${BUILD_CONFIGURATION}/${APP_NAME}" 2>/dev/null)

  printf '%s\n' "$latest_path"
}

validate_icon_png() {
  local width
  local height

  width="$(sips -g pixelWidth "$ICON_PNG" 2>/dev/null | awk '/pixelWidth/ { print $2 }')"
  height="$(sips -g pixelHeight "$ICON_PNG" 2>/dev/null | awk '/pixelHeight/ { print $2 }')"

  if [ -z "$width" ] || [ -z "$height" ]; then
    echo "Unable to inspect icon source: $ICON_PNG" >&2
    exit 1
  fi

  if [ "$width" != "$height" ]; then
    echo "Icon source must be square. Found ${width}x${height}: $ICON_PNG" >&2
    exit 1
  fi

  if [ "$width" -lt 1024 ]; then
    echo "Icon source must be at least 1024x1024. Found ${width}x${height}: $ICON_PNG" >&2
    exit 1
  fi
}

generate_icns() {
  local input_png="$1"
  local output_icns="$2"
  local tmp_dir
  local iconset_dir

  tmp_dir="$(mktemp -d)"
  iconset_dir="${tmp_dir}/AppIcon.iconset"
  mkdir -p "$iconset_dir"

  trap 'rm -rf "$tmp_dir"' RETURN

  sips -z 16 16 "$input_png" --out "${iconset_dir}/icon_16x16.png" >/dev/null
  sips -z 32 32 "$input_png" --out "${iconset_dir}/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$input_png" --out "${iconset_dir}/icon_32x32.png" >/dev/null
  sips -z 64 64 "$input_png" --out "${iconset_dir}/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$input_png" --out "${iconset_dir}/icon_128x128.png" >/dev/null
  sips -z 256 256 "$input_png" --out "${iconset_dir}/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$input_png" --out "${iconset_dir}/icon_256x256.png" >/dev/null
  sips -z 512 512 "$input_png" --out "${iconset_dir}/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$input_png" --out "${iconset_dir}/icon_512x512.png" >/dev/null
  cp "$input_png" "${iconset_dir}/icon_512x512@2x.png"

  iconutil -c icns "$iconset_dir" -o "$output_icns"
}

sign_app_if_configured() {
  need_cmd codesign

  if [ "$CODESIGN_IDENTITY" = "-" ]; then
    codesign --force --deep --sign - "$APP_BUNDLE"
    return
  fi

  codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

need_cmd create-dmg
need_cmd ditto
need_cmd iconutil
need_cmd plutil
need_cmd sips
need_cmd swift

if [ ! -f "$ICON_PNG" ]; then
  echo "Icon source not found: $ICON_PNG" >&2
  exit 1
fi

validate_icon_png

echo "Building ${APP_NAME} (${BUILD_CONFIGURATION})..."
swift build -c "$BUILD_CONFIGURATION"

latest_build="$(find_latest_build)"
if [ -z "$latest_build" ]; then
  echo "No built ${APP_NAME} binary found in .build/${BUILD_CONFIGURATION}." >&2
  exit 1
fi

build_stamp="$(date -r "$latest_build" '+%Y%m%d-%H%M%S')"
short_version="0.1.0"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  short_version="$(git describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")"
fi
short_version="${short_version#v}"
bundle_version="$(date -r "$latest_build" '+%Y%m%d%H%M%S')"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$DIST_DIR"
ditto "$latest_build" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

generate_icns "$ICON_PNG" "$ICON_ICNS"
ditto "$ICON_PNG" "$STATUS_BAR_SOURCE_PNG"

cat > "$INFO_PLIST" <<EOF_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${short_version}</string>
  <key>CFBundleVersion</key>
  <string>${bundle_version}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MINIMUM_SYSTEM_VERSION}</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF_PLIST

plutil -lint "$INFO_PLIST" >/dev/null
sign_app_if_configured

dmg_path="${DIST_DIR}/${APP_NAME}-${build_stamp}.dmg"
dmg_staging="$(mktemp -d)"
trap 'rm -rf "$dmg_staging"' EXIT
rm -f "$dmg_path" "$ZIP_PATH" "$LATEST_DMG_PATH"
find "$DIST_DIR" -maxdepth 1 -type f -name "${APP_NAME}-*.dmg" ! -name "${APP_NAME}-latest.dmg" -delete
find "$DIST_DIR" -maxdepth 1 -type f -name "rw.*.${APP_NAME}-*.dmg" -delete
ditto "$APP_BUNDLE" "${dmg_staging}/${APP_NAME}.app"

create-dmg \
  --volname "${APP_NAME}" \
  --volicon "$ICON_ICNS" \
  --hdiutil-retries "$CREATE_DMG_RETRIES" \
  --window-pos 200 120 \
  --window-size 640 420 \
  --icon-size 120 \
  --icon "${APP_NAME}.app" 170 190 \
  --hide-extension "${APP_NAME}.app" \
  --app-drop-link 470 190 \
  "$dmg_path" \
  "$dmg_staging"

ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
ditto "$dmg_path" "$LATEST_DMG_PATH"

echo "Latest build: $latest_build"
echo "App bundle: ${APP_BUNDLE}"
echo "ZIP: ${ZIP_PATH}"
echo "DMG: ${dmg_path}"
echo "Latest DMG Alias: ${LATEST_DMG_PATH}"
