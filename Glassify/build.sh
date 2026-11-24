#!/bin/bash
# Builds Glassify.app next to this folder.  ./build.sh        -> the app to keep and share (Apple silicon + Intel)
#                                            ./build.sh debug  -> a development build with the test hook compiled in
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-release}"
OUT="build"
APP="../Glassify.app"
[ "$MODE" = debug ] && APP="$OUT/Glassify.app"
mkdir -p "$OUT"
FLAGS=(-swift-version 5 -O -whole-module-optimization)
[ "$MODE" = debug ] && FLAGS+=(-D DEBUG)

if [ "$MODE" = debug ]; then
  swiftc "${FLAGS[@]}" -target "$(uname -m)-apple-macos14.2" Sources/*.swift -o "$OUT/Glassify-bin"
else
  swiftc "${FLAGS[@]}" -target arm64-apple-macos14.2 Sources/*.swift -o "$OUT/Glassify-arm64"
  swiftc "${FLAGS[@]}" -target x86_64-apple-macos14.2 Sources/*.swift -o "$OUT/Glassify-x86_64"
  lipo -create "$OUT/Glassify-arm64" "$OUT/Glassify-x86_64" -output "$OUT/Glassify-bin"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Web"
cp "$OUT/Glassify-bin" "$APP/Contents/MacOS/Glassify"
cp Info.plist "$APP/Contents/Info.plist"
cp Web/index.html "$APP/Contents/Resources/Web/index.html"
[ -f Glassify.icns ] && cp Glassify.icns "$APP/Contents/Resources/Glassify.icns"
# No Apple developer certificate on this Mac, so the app is signed "ad hoc" (to run locally and keep its permissions stable).
codesign --force --sign - --identifier app.glassify.widget "$APP"
echo "built $APP"
