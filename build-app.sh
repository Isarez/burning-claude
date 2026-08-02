#!/bin/bash
# Builds BurningClaude.app.
#
# Uses SwiftPM + a hand-assembled bundle rather than xcodebuild, so this works
# with only the Command Line Tools installed (no full Xcode required).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="BurningClaude"
# Changed from com.local.claudetokenmeter, which it had to be. macOS keys an
# app's notification record by bundle identifier and writes that record — icon
# included — the first time the app asks for authorization. It never picks up an
# icon added to the bundle later, which is why banners drew a blank white square
# however correct the .icns was. A new identifier gets a new record.
#
# Preferences.adoptLegacyDomain copies the settings out of the old UserDefaults
# domain on first run. The keychain service is deliberately *not* renamed, so
# stored session keys are untouched.
BUNDLE_ID="com.local.burningclaude"
VERSION="1.0.0"
CONFIG="${1:-release}"
APP="build/${APP_NAME}.app"

ICON="Resources/AppIcon.icns"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"

# The icon is drawn from source rather than checked in as pixels, so a missing
# or stale .icns rebuilds itself. See Tools/MakeIcon.swift.
if [ ! -f "$ICON" ] || [ Tools/MakeIcon.swift -nt "$ICON" ]; then
  echo "==> Drawing icon"
  swift Tools/MakeIcon.swift "$ICON"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>Burning Claude</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <!-- No Dock icon to show, but this is what Finder, the installer, and
         notification banners use.

         CFBundleIconName is deliberately absent. It names an image inside a
         compiled asset catalog (Assets.car), which a hand-assembled bundle
         does not have. Finder tolerates that and falls back to the .icns, but
         notification banners resolve the name strictly and drew a white box
         when it was set. -->
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. A bundle identifier plus a signature is what lets
# UserNotifications work; without it the app still runs, but alerts are skipped.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null \
  || echo "    (ad-hoc signing failed; app will run without notifications)"

echo
echo "Built $APP"
echo "Run it with:  open $APP"
echo "Install with: cp -R $APP /Applications/"
