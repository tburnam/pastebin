#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PasteBin"
BUNDLE_ID="${BUNDLE_ID:-io.github.tylerburnam.pastebin}"
ICON_PNG="pastebinicon.png"
MINIMUM_SYSTEM_VERSION="14.0"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Tyler Burnam (EZM2SRN8W6)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-PasteBin}"
NOTARIZE="${NOTARIZE:-auto}"
CREATE_DMG_RETRIES="${CREATE_DMG_RETRIES:-20}"
DIST_DIR="dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"
ICON_ICNS="${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
STATUS_BAR_SOURCE_PNG="${APP_BUNDLE}/Contents/Resources/StatusBarSource.png"
ZIP_PATH="${DIST_DIR}/${APP_NAME}.app.zip"
LATEST_DMG_PATH="${DIST_DIR}/${APP_NAME}-latest.dmg"
GITHUB_REPO="tburnam/pastebin"
SPARKLE_SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
PUBLISH=false
BUMP_TYPE=""

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

should_notarize() {
  if [ "$NOTARIZE" = "true" ]; then
    return 0
  elif [ "$NOTARIZE" = "false" ]; then
    return 1
  fi
  # auto: notarize when using a Developer ID identity
  [ "$CODESIGN_IDENTITY" != "-" ]
}

sign_app_if_configured() {
  need_cmd codesign

  if [ "$CODESIGN_IDENTITY" = "-" ]; then
    codesign --force --deep --sign - "$APP_BUNDLE"
    return
  fi

  codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
}

notarize_and_staple() {
  local artifact="$1"

  need_cmd xcrun

  echo "Submitting ${artifact} for notarization..."
  xcrun notarytool submit "$artifact" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  if [[ "$artifact" != *.zip ]]; then
    echo "Stapling notarization ticket to ${artifact}..."
    xcrun stapler staple "$artifact"
  fi
}

get_latest_tag() {
  git tag -l --sort=-v:refname | head -1 | sed 's/^v//'
}

bump_version() {
  local version="$1"
  local bump_type="$2"
  local major minor patch

  IFS='.' read -r major minor patch <<< "$version"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"

  case "$bump_type" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    patch) echo "${major}.${minor}.$((patch + 1))" ;;
    *) echo "$version" ;;
  esac
}

prompt_version() {
  local current
  current="$(get_latest_tag)"
  current="${current:-0.0.0}"

  if [ -n "$BUMP_TYPE" ]; then
    RELEASE_VERSION="$(bump_version "$current" "$BUMP_TYPE")"
    echo "Will release as v${RELEASE_VERSION}"
    return
  fi

  local next_major next_minor next_patch
  next_major="$(bump_version "$current" major)"
  next_minor="$(bump_version "$current" minor)"
  next_patch="$(bump_version "$current" patch)"

  echo ""
  echo "Current version: ${current}"
  echo ""
  echo "  1) patch  → ${next_patch}"
  echo "  2) minor  → ${next_minor}"
  echo "  3) major  → ${next_major}"
  echo ""
  printf "Select bump type [1/2/3]: "
  read -r choice

  case "$choice" in
    1|patch) RELEASE_VERSION="$next_patch" ;;
    2|minor) RELEASE_VERSION="$next_minor" ;;
    3|major) RELEASE_VERSION="$next_major" ;;
    *)
      echo "Invalid choice." >&2
      exit 1
      ;;
  esac

  echo "Will release as v${RELEASE_VERSION}"
}

generate_appcast() {
  local tag="v${RELEASE_VERSION}"
  local zip_size
  local signature
  local download_url

  zip_size="$(stat -f '%z' "$ZIP_PATH")"
  download_url="https://github.com/${GITHUB_REPO}/releases/download/${tag}/${APP_NAME}.app.zip"

  echo "Signing update with Sparkle EdDSA key..."
  signature="$("${SPARKLE_SIGN_UPDATE}" "$ZIP_PATH" 2>&1 | grep 'sparkle:edSignature=' | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/')"

  if [ -z "$signature" ]; then
    echo "Failed to generate Sparkle EdDSA signature." >&2
    exit 1
  fi

  echo "Generating appcast.xml..."
  cat > appcast.xml <<EOF_APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${APP_NAME}</title>
    <link>https://github.com/${GITHUB_REPO}</link>
    <item>
      <title>${APP_NAME} ${tag}</title>
      <pubDate>$(date -R)</pubDate>
      <sparkle:version>${bundle_version}</sparkle:version>
      <sparkle:shortVersionString>${RELEASE_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
      <enclosure
        url="${download_url}"
        length="${zip_size}"
        type="application/octet-stream"
        sparkle:edSignature="${signature}"
      />
    </item>
  </channel>
</rss>
EOF_APPCAST
}

publish_to_github() {
  need_cmd gh

  local tag="v${RELEASE_VERSION}"

  generate_appcast

  echo ""
  echo "Creating GitHub release ${tag}..."
  git add appcast.xml
  git commit -m "Update appcast.xml for ${tag}"
  git tag "$tag"
  git push origin main "$tag"

  gh release create "$tag" \
    "$LATEST_DMG_PATH#${APP_NAME}-latest.dmg" \
    "$ZIP_PATH" \
    --repo "$GITHUB_REPO" \
    --title "${APP_NAME} ${tag}" \
    --generate-notes

  echo ""
  echo "Published: https://github.com/${GITHUB_REPO}/releases/tag/${tag}"
}

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=true ;;
    --patch) BUMP_TYPE=patch ;;
    --minor) BUMP_TYPE=minor ;;
    --major) BUMP_TYPE=major ;;
  esac
done

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

if [ "$PUBLISH" = true ]; then
  need_cmd gh
  need_cmd git

  if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree is dirty. Commit or stash changes before publishing." >&2
    exit 1
  fi

  prompt_version
fi

echo "Building ${APP_NAME} (${BUILD_CONFIGURATION})..."
swift build -c "$BUILD_CONFIGURATION"

latest_build="$(find_latest_build)"
if [ -z "$latest_build" ]; then
  echo "No built ${APP_NAME} binary found in .build/${BUILD_CONFIGURATION}." >&2
  exit 1
fi

build_stamp="$(date -r "$latest_build" '+%Y%m%d-%H%M%S')"
if [ -n "${RELEASE_VERSION:-}" ]; then
  short_version="$RELEASE_VERSION"
else
  short_version="0.1.0"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    short_version="$(git describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")"
  fi
  short_version="${short_version#v}"
fi
bundle_version="$(date -r "$latest_build" '+%Y%m%d%H%M%S')"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$DIST_DIR"
ditto "$latest_build" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

generate_icns "$ICON_PNG" "$ICON_ICNS"
ditto "$ICON_PNG" "$STATUS_BAR_SOURCE_PNG"

# Embed Sparkle framework
sparkle_framework="$(find .build/artifacts/sparkle -path '*/macos-*/Sparkle.framework' -maxdepth 5 | head -1)"
if [ -n "$sparkle_framework" ]; then
  echo "Embedding Sparkle.framework..."
  mkdir -p "$APP_BUNDLE/Contents/Frameworks"
  ditto "$sparkle_framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

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
  <key>SUFeedURL</key>
  <string>https://raw.githubusercontent.com/${GITHUB_REPO}/main/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>ZptyKEaSdXTUK6ET98vBSwVDaU0I5V6a9pxL494+7U8=</string>
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

if should_notarize; then
  notarize_and_staple "$dmg_path"
  notarize_and_staple "$ZIP_PATH"
  echo "Notarization complete."
fi

ditto "$dmg_path" "$LATEST_DMG_PATH"

echo ""
echo "Latest build: $latest_build"
echo "App bundle: ${APP_BUNDLE}"
echo "ZIP: ${ZIP_PATH}"
echo "DMG: ${dmg_path}"
echo "Latest DMG Alias: ${LATEST_DMG_PATH}"

if should_notarize; then
  echo "Status: signed + notarized (ready for distribution)"
else
  echo "Status: ad-hoc signed (local use only)"
fi

if [ "$PUBLISH" = true ]; then
  publish_to_github
fi
