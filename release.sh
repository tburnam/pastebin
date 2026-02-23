#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PasteBin"
BUNDLE_ID="com.tylerburnam.pastebin"
ICON_PNG="pastebinicon.png"
DIST_DIR="dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"
ICON_ICNS="${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

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
  done < <(find .build -type f \( -path "*/release/${APP_NAME}" -o -path "*/debug/${APP_NAME}" \) 2>/dev/null)

  printf '%s\n' "$latest_path"
}

generate_icns() {
  local input_png="$1"
  local output_icns="$2"
  local tmp_dir
  local multi_tiff

  tmp_dir="$(mktemp -d)"
  multi_tiff="${tmp_dir}/AppIconMulti.tiff"

  trap 'rm -rf "$tmp_dir"' RETURN

  sips -z 16 16 -s format tiff "$input_png" --out "${tmp_dir}/icon_16.tiff" >/dev/null
  sips -z 32 32 -s format tiff "$input_png" --out "${tmp_dir}/icon_32.tiff" >/dev/null
  sips -z 64 64 -s format tiff "$input_png" --out "${tmp_dir}/icon_64.tiff" >/dev/null
  sips -z 128 128 -s format tiff "$input_png" --out "${tmp_dir}/icon_128.tiff" >/dev/null
  sips -z 256 256 -s format tiff "$input_png" --out "${tmp_dir}/icon_256.tiff" >/dev/null
  sips -z 512 512 -s format tiff "$input_png" --out "${tmp_dir}/icon_512.tiff" >/dev/null
  sips -z 1024 1024 -s format tiff "$input_png" --out "${tmp_dir}/icon_1024.tiff" >/dev/null

  tiffutil -cat \
    "${tmp_dir}/icon_16.tiff" \
    "${tmp_dir}/icon_32.tiff" \
    "${tmp_dir}/icon_64.tiff" \
    "${tmp_dir}/icon_128.tiff" \
    "${tmp_dir}/icon_256.tiff" \
    "${tmp_dir}/icon_512.tiff" \
    "${tmp_dir}/icon_1024.tiff" \
    -out "$multi_tiff" >/dev/null 2>&1

  tiff2icns "$multi_tiff" "$output_icns"
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

need_cmd create-dmg
need_cmd sips
need_cmd tiffutil
need_cmd tiff2icns

if [ ! -f "$ICON_PNG" ]; then
  echo "Icon source not found: $ICON_PNG" >&2
  exit 1
fi

latest_build="$(find_latest_build)"
if [ -z "$latest_build" ]; then
  echo "No built ${APP_NAME} binary found in .build. Run 'swift build -c release' first." >&2
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
cp "$latest_build" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

generate_icns "$ICON_PNG" "$ICON_ICNS"

cat > "$INFO_PLIST" <<EOF_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
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
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF_PLIST

dmg_path="${DIST_DIR}/${APP_NAME}-${build_stamp}.dmg"
dmg_staging="$(mktemp -d)"
trap 'rm -rf "$dmg_staging"' EXIT
cp -R "$APP_BUNDLE" "$dmg_staging/"
rm -f "$dmg_path"

create-dmg \
  --volname "${APP_NAME}" \
  --volicon "$ICON_ICNS" \
  --window-pos 200 120 \
  --window-size 640 420 \
  --icon-size 120 \
  --icon "${APP_NAME}.app" 170 190 \
  --hide-extension "${APP_NAME}.app" \
  --app-drop-link 470 190 \
  "$dmg_path" \
  "$dmg_staging"

echo "Latest build: $latest_build"
echo "App bundle: ${APP_BUNDLE}"
echo "DMG: ${dmg_path}"
