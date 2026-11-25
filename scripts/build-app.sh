#!/usr/bin/env bash
# Baut Cadence.app aus dem Swift-Paket.
#
#   ./scripts/build-app.sh            → build/Cadence.app (Release, ad-hoc signiert)
#   CODESIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh
#                                     → mit eigenem Zertifikat signiert; macOS merkt sich die
#                                       Berechtigungen dann auch über Updates hinweg.
#
# Weitere Variablen:
#   SCRATCH_PATH  Build-Zwischendateien (Standard: .build). Bei synchronisierten Ordnern
#                 (Nextcloud, iCloud, Dropbox) unbedingt außerhalb ablegen, z. B. ~/Library/Caches/cadence-build
#   APP_DIR       Zielordner für Cadence.app (Standard: build)
#   SDKROOT       macOS-SDK. Ohne Xcode (nur Command Line Tools) wählt das Skript automatisch
#                 ein SDK, das ohne SwiftUI-Macro-Plugin auskommt.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
IDENTITY="${CODESIGN_IDENTITY:--}"
SCRATCH_PATH="${SCRATCH_PATH:-.build}"
APP_DIR="${APP_DIR:-build}"
APP="$APP_DIR/Cadence.app"

# Nur Command Line Tools ohne Xcode: Neuere SDKs verlangen das SwiftUIMacros-Plugin, das nur
# Xcode mitbringt. Dann das neueste SDK der Command Line Tools mit Major-Version <= 26 nehmen.
if [ -z "${SDKROOT:-}" ] && [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
  CLT_SDKS=/Library/Developer/CommandLineTools/SDKs
  FALLBACK="$(ls -d "$CLT_SDKS"/MacOSX[0-9]*.sdk 2>/dev/null \
    | sed -E 's#.*/MacOSX([0-9]+)(\.[0-9]+)?\.sdk#\1 &#' \
    | awk '$1 <= 26 { print $2 }' | sort -V | tail -1)"
  if [ -n "$FALLBACK" ]; then
    export SDKROOT="$FALLBACK"
    echo "▸ Kein Xcode gefunden – baue gegen $SDKROOT"
  fi
fi

echo "▸ swift build ($CONFIG)"
swift build -c "$CONFIG" --product Cadence --scratch-path "$SCRATCH_PATH"
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH_PATH" --show-bin-path)"

echo "▸ App-Bundle zusammenstellen"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Cadence" "$APP/Contents/MacOS/Cadence"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
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
