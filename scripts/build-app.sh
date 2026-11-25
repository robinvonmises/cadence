#!/usr/bin/env bash
# Baut Cadence.app aus dem Swift-Paket.
#
#   ./scripts/build-app.sh            → build/Cadence.app (Release, ad-hoc signiert)
#   CODESIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh
#                                     → mit eigenem Zertifikat signiert; macOS merkt sich die
#                                       Berechtigungen dann auch über Updates hinweg.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP="build/Cadence.app"

echo "▸ swift build ($CONFIG)"
swift build -c "$CONFIG" --product Cadence
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ App-Bundle zusammenstellen"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Cadence" "$APP/Contents/MacOS/Cadence"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" || true
fi
# Ressourcen-Bundles der Abhängigkeiten (falls vorhanden)
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

echo "▸ Signieren (Identität: $IDENTITY)"
codesign --force --deep --options runtime \
  --entitlements Resources/Cadence.entitlements \
  --sign "$IDENTITY" "$APP"

echo "✓ Fertig: $APP"
echo "  Starten mit: open \"$APP\""
