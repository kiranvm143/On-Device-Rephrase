#!/bin/zsh
# Builds Rephrase.app (menu-bar app) from the Swift package.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --build-system native

APP="build/Rephrase.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Rephrase "$APP/Contents/MacOS/Rephrase"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.local.rephrase</string>
    <key>CFBundleName</key><string>Rephrase</string>
    <key>CFBundleDisplayName</key><string>Rephrase</string>
    <key>CFBundleExecutable</key><string>Rephrase</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature with a requirement based on the bundle ID rather than the build's hash,
# so the Accessibility grant survives rebuilds.
codesign --force --sign - --identifier com.local.rephrase \
    -r='designated => identifier "com.local.rephrase"' "$APP"
echo "Built $APP"

# Install into ~/Applications so `open -a Rephrase` and Spotlight find it.
mkdir -p ~/Applications
rm -rf ~/Applications/Rephrase.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Rephrase.app"
