#!/bin/bash
# Publica una versión de Moodboard en GitHub Releases con auto-actualización por Sparkle.
#
#   SHORT_VERSION=1.1.0 BUILD_VERSION=2 ./release.sh
#
# Hace: compila el .app (Sparkle embebido, firma ad-hoc) → lo comprime → genera el appcast firmado
# con la clave EdDSA del Keychain → crea el release vX.Y.Z subiendo el .zip y el appcast.xml.
#
# El feed (SUFeedURL) apunta a releases/latest/download/appcast.xml, así que los usuarios siempre
# ven la última versión. Cada release lleva su propio appcast con la entrada de esa versión.
set -euo pipefail
cd "$(dirname "$0")"

SHORT_VERSION="${SHORT_VERSION:-1.5.8}"
BUILD_VERSION="${BUILD_VERSION:-15}"
TAG="v${SHORT_VERSION}"
REPO="simoniturrap/Moodboard"
ZIP="Moodboard-${SHORT_VERSION}.zip"
UPDATES="dist/updates"
SIGN_TOOL=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"

export SHORT_VERSION BUILD_VERSION
./build.sh

echo "▸ Comprimiendo el .app…"
rm -rf "$UPDATES"
mkdir -p "$UPDATES"
ditto -c -k --sequesterRsrc --keepParent "dist/Moodboard.app" "$UPDATES/$ZIP"

echo "▸ Generando appcast firmado…"
[ -x "$SIGN_TOOL" ] || { echo "✗ Falta $SIGN_TOOL (swift package resolve)"; exit 1; }
"$SIGN_TOOL" "$UPDATES/" \
  --download-url-prefix "https://github.com/${REPO}/releases/download/${TAG}/"

echo "▸ Publicando release ${TAG}…"
gh release create "$TAG" \
  "$UPDATES/$ZIP" \
  "$UPDATES/appcast.xml" \
  --repo "$REPO" \
  --title "Moodboard ${SHORT_VERSION}" \
  --latest \
  --notes "Versión ${SHORT_VERSION}. Actualización automática vía Sparkle.

Primera apertura: clic derecho sobre Moodboard.app → **Abrir** (firma ad-hoc). A partir de ahí, las actualizaciones se instalan solas desde la propia app."

echo "✓ Publicado: https://github.com/${REPO}/releases/tag/${TAG}"
