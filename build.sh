#!/bin/bash
# Compila Moodboard y arma el bundle Moodboard.app en ./dist, con Sparkle embebido para
# auto-actualización. Firma ad-hoc (sin cuenta Apple): la primera apertura pide clic derecho → Abrir;
# los updates que entregue Sparkle se validan con la clave EdDSA y se instalan sin fricción.
#
# Versión: se puede fijar con variables de entorno.
#   SHORT_VERSION=1.1.0 BUILD_VERSION=2 ./build.sh
set -e
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="dist/Moodboard.app"

# Versión mostrada y número de compilación (Sparkle compara CFBundleVersion para decidir updates).
SHORT_VERSION="${SHORT_VERSION:-1.5.1}"
BUILD_VERSION="${BUILD_VERSION:-8}"

# Feed del appcast y clave pública EdDSA (la privada vive en el Keychain de quien publica).
SU_FEED_URL="${SU_FEED_URL:-https://github.com/simoniturrap/Moodboard/releases/latest/download/appcast.xml}"
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-djIX2PgXCRl0i6FcSKmAHy+ej37dWAkbP6tFYDkYM+M=}"

echo "▸ Compilando ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Moodboard"

echo "▸ Armando el bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Moodboard"

echo "▸ Embebiendo Sparkle…"
FRAMEWORK="$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' | head -1)"
[ -n "$FRAMEWORK" ] || { echo "✗ No encuentro Sparkle.framework (corré: swift package resolve)"; exit 1; }
cp -R "$FRAMEWORK" "$APP/Contents/Frameworks/"
# El binario busca el framework junto a sí mismo dentro del bundle.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Moodboard"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Moodboard</string>
  <key>CFBundleDisplayName</key><string>Moodboard</string>
  <key>CFBundleIdentifier</key><string>com.simon.moodboard</string>
  <key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Moodboard</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Para agregar tus fotos a los tableros.</string>
  <key>SUFeedURL</key><string>${SU_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SU_PUBLIC_ED_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

echo "▸ Firmando (ad-hoc)…"
# Primero el framework (y su código anidado: XPC, Autoupdate, Updater.app), luego la app, que
# invalidaría su firma si se hiciera antes del install_name_tool.
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "✓ Listo: $APP ($SHORT_VERSION, build $BUILD_VERSION)"
