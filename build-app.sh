#!/bin/bash
# Builds Clementine.app (universal: Apple silicon + Intel) into ./dist.
# Usage: ./build-app.sh            (run on a Mac with Xcode or the Command Line Tools)
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/Clementine.app"
VERSION="${VERSION:-1.0.0}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Clementine"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clementine"

# Optional: bundle an ffmpeg binary placed in Resources/ffmpeg.
if [ -x Resources/ffmpeg ]; then
  cp Resources/ffmpeg "$APP/Contents/Resources/ffmpeg"
fi

# App icon from Resources/AppIcon.png (1024×1024, rendered from icon.svg).
if [ -f Resources/AppIcon.png ] && command -v iconutil >/dev/null; then
  TMP="$(mktemp -d)"
  ICONSET="$TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$TMP"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Clementine</string>
  <key>CFBundleDisplayName</key><string>Clementine</string>
  <key>CFBundleIdentifier</key><string>com.stefanoneve.clementine</string>
  <key>CFBundleExecutable</key><string>Clementine</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Clementine usa Pages, Numbers e Keynote per convertire i documenti iWork e Office.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Qualsiasi file</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.item</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will run it locally.
codesign --force --deep --sign - "$APP"

(cd dist && rm -f Clementine.zip && ditto -c -k --keepParent Clementine.app Clementine.zip)
echo "Pronto: $APP (e dist/Clementine.zip)"
