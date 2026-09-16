#!/bin/bash
# Wraps the Swift package executable into a real .app bundle (menu-bar only).
# Usage: ./scripts/make-app.sh   (output: dist/SentryBar.app)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SentryBar"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building release binary..."
swift build -c release

# SPM executable target is still named SystemMonitor; we bundle it as SentryBar.
BIN="$(swift build -c release --show-bin-path)/SystemMonitor"
HELPER="$(swift build -c release --show-bin-path)/FanHelper"

echo "==> Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$HELPER" "$APP/Contents/MacOS/FanHelper"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>local.sysmon.SystemMonitor</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc codesigning (local dev)..."
find "$APP" -name "._*" -delete
find "$APP" -name ".DS_Store" -delete
# Strip quarantine + metadata xattrs immediately before signing
# (must be done after all file copies so nothing re-attaches them)
xattr -cr "$APP"
find "$APP" -type d -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
# Sign with an identifier-only designated requirement (no cdhash) so the
# Accessibility/Input Monitoring permissions survive future rebuilds.
# Retry: macOS/Finder can re-attach xattrs right after the copies.
REQ_FILE="$(mktemp)"
printf 'designated => identifier "local.sysmon.SystemMonitor"\n' > "$REQ_FILE"
for attempt in 1 2 3; do
  find "$APP" -name "._*" -delete 2>/dev/null || true
  find "$APP" -name ".DS_Store" -delete 2>/dev/null || true
  xattr -cr "$APP" 2>/dev/null || true
  if codesign --force --sign - --identifier "local.sysmon.SystemMonitor" -r "$REQ_FILE" "$APP" 2>/dev/null; then
    break
  fi
  sleep 1
done
rm -f "$REQ_FILE"
codesign --verify --deep --strict "$APP" || true

echo "==> Done: $APP"
echo "    Run with: open $APP"
