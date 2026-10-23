#!/bin/sh
# Compila, assembla BatteryGuard.app, firma ad-hoc e produce .zip e .dmg,
# più il pacchetto versionato in dist/release (dmg, zip, SHA256SUMS).
# Usa swiftc diretto: lo `swift build` dei Command Line Tools 14.3 su macOS 26 fallisce
# cercando la PlatformPath (che esiste solo con Xcode). Package.swift resta valido per toolchain aggiornate.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/manual"
DIST="$ROOT/dist"
NAME="BatteryGuard"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
APP="$DIST/$NAME.app"
DMG="$DIST/$NAME.dmg"
ZIP="$DIST/$NAME.zip"
RELEASE="$DIST/release"
# Binari universali: arm64 e x86_64 (Mac Intel). Gli strumenti di build girano sull'architettura di questo Mac
HOST_TARGET="$(uname -m)-apple-macos13"
ARCHS="arm64 x86_64"

rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

for ARCH in $ARCHS; do
  SWIFTC="xcrun swiftc -O -target $ARCH-apple-macos13"
  OUT="$BUILD/$ARCH"
  mkdir -p "$OUT"

  $SWIFTC -module-name SMCKit -parse-as-library \
    -emit-module -emit-module-path "$OUT/SMCKit.swiftmodule" \
    -emit-library -static -o "$OUT/libSMCKit.a" "$ROOT"/Sources/SMCKit/*.swift

  $SWIFTC -I "$OUT" -L "$OUT" -lSMCKit -framework IOKit \
    "$ROOT/Sources/batteryguard-helper/main.swift" -o "$OUT/batteryguard-helper"

  $SWIFTC -module-name BatteryGuard -parse-as-library -I "$OUT" -L "$OUT" -lSMCKit -framework IOKit \
    "$ROOT"/Sources/BatteryGuard/*.swift -o "$OUT/BatteryGuard"
done

for BIN in BatteryGuard batteryguard-helper; do
  lipo -create -output "$BUILD/$BIN" "$BUILD"/arm64/"$BIN" "$BUILD"/x86_64/"$BIN"
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/BatteryGuard" "$BUILD/batteryguard-helper" "$APP/Contents/MacOS/"
cp "$ROOT/Resources/install.sh" "$ROOT/Resources/uninstall.sh" "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Localizzazioni: le cartelle .lproj fanno comparire l'app in Impostazioni > Lingua e regione > Applicazioni.
# Le .strings vanno nel bundle in formato binario, come le compila Xcode
for LPROJ in "$ROOT"/Resources/*.lproj; do
  DEST_LPROJ="$APP/Contents/Resources/$(basename "$LPROJ")"
  mkdir -p "$DEST_LPROJ"
  for STRINGS in "$LPROJ"/*.strings; do
    plutil -convert binary1 -o "$DEST_LPROJ/$(basename "$STRINGS")" "$STRINGS"
  done
done

# Firma ad-hoc: prima l'eseguibile annidato con identificativo proprio, poi il bundle
codesign --force --sign - --identifier com.alessiocardelli.batteryguard.helper \
  "$APP/Contents/MacOS/batteryguard-helper"
codesign --force --sign - "$APP"

# Zip: un solo "Apri comunque" (sull'app), contro i due del dmg. ditto conserva firma e attributi del bundle
ditto -c -k --keepParent "$APP" "$ZIP"

# Dmg con finestra di installazione curata (sfondo, posizioni, icona del volume) scritta da dmgbuild
# direttamente nel .DS_Store: niente AppleScript, quindi nessun permesso di automazione su Finder.
# dmgbuild vive in un venv dentro .build, creato al primo uso.
VENV="$ROOT/.build/dmgbuild-venv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "dmgbuild==1.6.7"
fi
xcrun swiftc -O -target "$HOST_TARGET" "$ROOT/scripts/tools/make-dmg-background.swift" -o "$BUILD/make-dmg-background"
# Produce background.png e background@2x.png: dmgbuild li unisce in un TIFF multi-risoluzione
"$BUILD/make-dmg-background" "$BUILD/background"
"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" \
  -D app="$APP" -D background="$BUILD/background.png" -D icon="$ROOT/Resources/AppIcon.icns" \
  "$NAME" "$DMG" >/dev/null
codesign --force --sign - "$DMG"

# Pacchetto da pubblicare: stessi file con la versione nel nome e checksum da mettere nella pagina di download
mkdir -p "$RELEASE"
cp "$DMG" "$RELEASE/$NAME-$VERSION.dmg"
cp "$ZIP" "$RELEASE/$NAME-$VERSION.zip"
(cd "$RELEASE" && shasum -a 256 "$NAME-$VERSION.dmg" "$NAME-$VERSION.zip" > SHA256SUMS)

echo "app: $APP"
echo "zip: $ZIP"
echo "dmg: $DMG"
echo "release $VERSION: $RELEASE"
