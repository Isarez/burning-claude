#!/bin/bash
# Builds the release artifacts and prints the checksums a Homebrew cask needs.
#
# Two artifacts, because they serve different installs:
#   - a .zip of the .app, which is what `brew install --cask` consumes. The
#     cask `app` stanza just moves the bundle into /Applications, so there is
#     no sudo and `brew uninstall` is a clean delete.
#   - the .pkg, for people who would rather double-click an installer. It runs
#     the pre/postinstall scripts, which the zip route skips — those only quit
#     a running copy, which Homebrew handles itself via the `quit` stanza.
#
# `ditto -c -k --keepParent` rather than `zip -r`: it preserves the resource
# forks and the code signature inside the bundle. A plain `zip` corrupts the
# ad-hoc signature, and an app whose signature does not validate is killed on
# launch rather than merely warned about.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="BurningClaude"
VERSION="1.0.0"
APP="build/${APP_NAME}.app"
DIST="dist"
ZIP="${DIST}/${APP_NAME}-${VERSION}.zip"

./make-pkg.sh

echo "==> Zipping $APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Artifacts:"
ls -lh "${DIST}/${APP_NAME}-${VERSION}".{zip,pkg} | awk '{print "  " $9 "  " $5}'
echo
echo "sha256 (paste into the cask):"
shasum -a 256 "$ZIP" | awk '{print "  " $1}'
