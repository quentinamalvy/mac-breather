#!/bin/zsh
# Builds Mac Breather and installs it in ~/Applications.
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/Mac Breather.app"
mkdir -p build "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -o build/MacBreather Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework UserNotifications
cp build/MacBreather "$APP/Contents/MacOS/MacBreather"
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
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "OK: $APP"
