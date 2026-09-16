#!/bin/bash
# Builds a distributable DMG with the app + an /Applications shortcut.
# Usage: ./scripts/make-dmg.sh   (output: dist/SystemMonitor.dmg)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="SentryBar"
APP="dist/$APP_NAME.app"
STAGING="dist/dmg-staging"
VOLUME_NAME="SentryBar"

if [ ! -d "$APP" ]; then
  echo "==> Building app first (make-app.sh)..."
  ./scripts/make-app.sh
fi

echo "==> Staging DMG contents..."
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating DMG..."
rm -f "dist/$APP_NAME.dmg"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "dist/$APP_NAME.dmg"

rm -rf "$STAGING"
echo "==> Done: dist/$APP_NAME.dmg"
echo "    SHA-256: $(shasum -a 256 "dist/$APP_NAME.dmg" | awk '{print $1}')"
