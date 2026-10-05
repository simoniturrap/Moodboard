#!/bin/bash
# Compila Moodboard y arma el bundle Moodboard.app en ./dist
set -e
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="dist/Moodboard.app"

echo "▸ Compilando ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Moodboard"

echo "▸ Armando el bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Moodboard"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Moodboard</string>
  <key>CFBundleDisplayName</key><string>Moodboard</string>
  <key>CFBundleIdentifier</key><string>com.simon.moodboard</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Moodboard</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Para agregar tus fotos a los tableros.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ Listo: $APP"
