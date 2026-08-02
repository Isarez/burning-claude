#!/bin/bash
# Builds dist/BurningClaude-<version>.pkg, a double-clickable installer.
#
# Two stages, which is how a pkg with a real product name is made: `pkgbuild`
# turns the app bundle into a component package, then `productbuild` wraps that
# with Packaging/distribution.xml for the title, the macOS requirement, and the
# welcome and conclusion panes.
#
# The result is unsigned — signing needs a Developer ID certificate, which this
# project does not have. See the note printed at the end for how to install it.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="BurningClaude"
VERSION="$(cat VERSION)"
# Distinct from the app's own bundle identifier: this names the *receipt* macOS
# keeps for the install, not the app.
PKG_ID="com.local.burningclaude.app"
APP="build/${APP_NAME}.app"
STAGE="build/pkgroot"
DIST="dist"

./build-app.sh release

echo "==> Staging $APP"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

echo "==> Building component package"
mkdir -p "$DIST"
chmod +x Packaging/scripts/preinstall Packaging/scripts/postinstall
pkgbuild \
  --root "$STAGE" \
  --install-location /Applications \
  --identifier "$PKG_ID" \
  --version "$VERSION" \
  --scripts Packaging/scripts \
  "build/${APP_NAME}-component.pkg" >/dev/null

echo "==> Building installer"
productbuild \
  --distribution Packaging/distribution.xml \
  --package-path build \
  --resources Packaging/resources \
  "${DIST}/${APP_NAME}-${VERSION}.pkg" >/dev/null

rm -rf "$STAGE" "build/${APP_NAME}-component.pkg"

echo
echo "Built ${DIST}/${APP_NAME}-${VERSION}.pkg"
echo
echo "The package is unsigned, so double-clicking it gets refused by Gatekeeper."
echo "Install it either way:"
echo "  Right-click the .pkg > Open > Open        (once, per package)"
echo "  sudo installer -pkg ${DIST}/${APP_NAME}-${VERSION}.pkg -target /"
