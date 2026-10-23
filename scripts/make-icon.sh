#!/bin/sh
# Rigenera Resources/AppIcon.icns dal disegno in Resources/design. Da lanciare solo quando cambia il disegno:
# l'.icns è versionato e build.sh lo copia così com'è.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/icon"
SET="$WORK/AppIcon.iconset"
rm -rf "$WORK"
mkdir -p "$SET"

xcrun swiftc -O -target "$(uname -m)-apple-macos13" "$ROOT/scripts/tools/make-icon.swift" -o "$WORK/make-icon"
"$WORK/make-icon" "$ROOT/Resources/design/app-icon-source.webp" "$ROOT/Resources/design/app-icon-1024.png"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/Resources/design/app-icon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ROOT/Resources/design/app-icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
echo "icona: $ROOT/Resources/AppIcon.icns"
