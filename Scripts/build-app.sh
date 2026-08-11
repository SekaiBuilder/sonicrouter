#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SonicRouter"
CONFIGURATION="${1:-release}"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_FILE="$ROOT_DIR/Assets/AppIcon.icns"

cd "$ROOT_DIR"
UNIVERSAL_BUILD="${SONICROUTER_UNIVERSAL:-1}"
if [[ "$UNIVERSAL_BUILD" == "1" ]]; then
  ARM_BUILD_ARGS=(-c "$CONFIGURATION" --triple arm64-apple-macosx15.0)
  INTEL_BUILD_ARGS=(-c "$CONFIGURATION" --triple x86_64-apple-macosx15.0)
  swift build "${ARM_BUILD_ARGS[@]}" --product "$APP_NAME"
  ARM_BUILD_DIR="$(swift build "${ARM_BUILD_ARGS[@]}" --show-bin-path)"
  swift build "${INTEL_BUILD_ARGS[@]}" --product "$APP_NAME"
  INTEL_BUILD_DIR="$(swift build "${INTEL_BUILD_ARGS[@]}" --show-bin-path)"
else
  SWIFT_BUILD_ARGS=(-c "$CONFIGURATION")
  swift build "${SWIFT_BUILD_ARGS[@]}" --product "$APP_NAME"
  BUILD_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
fi

if [[ ! -f "$ICON_FILE" ]]; then
  swift "$ROOT_DIR/Scripts/make-icon.swift" "$ROOT_DIR/Assets"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
if [[ "$UNIVERSAL_BUILD" == "1" ]]; then
  xcrun lipo -create \
    "$ARM_BUILD_DIR/$APP_NAME" \
    "$INTEL_BUILD_DIR/$APP_NAME" \
    -output "$MACOS_DIR/$APP_NAME"
else
  cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
fi
cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>es</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>es</string>
    <string>en</string>
    <string>ja</string>
  </array>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>local.sonicrouter.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.4</string>
  <key>CFBundleVersion</key>
  <string>6</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHumanReadableCopyright</key>
  <string>© 2026 SonicRouter</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSQuitAlwaysKeepsWindows</key>
  <false/>
  <key>NSAudioCaptureUsageDescription</key>
  <string>SonicRouter necesita capturar el audio del sistema para silenciar y ajustar el volumen de cada app por separado.</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP_DIR" >/dev/null
  else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
  fi
fi

echo "$APP_DIR"
