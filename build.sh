#!/bin/zsh
# Builds Mac Breather and installs it in ~/Applications.
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/Mac Breather.app"
mkdir -p build "$APP/Contents/MacOS"
# One binary for Apple Silicon and Intel Macs, macOS 14 or later (Liquid Glass on macOS 26).
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target $arch-apple-macos14.0 -o build/MacBreather-$arch Sources/*.swift \
    -framework AppKit -framework SwiftUI
done
lipo -create build/MacBreather-arm64 build/MacBreather-x86_64 -output build/MacBreather
cp build/MacBreather "$APP/Contents/MacOS/MacBreather"
mkdir -p "$APP/Contents/Resources" && cp sounds/notify.wav "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.quentinamalvy.macbreather</string>
  <key>CFBundleName</key><string>Mac Breather</string>
  <key>CFBundleExecutable</key><string>MacBreather</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "OK: $APP"
