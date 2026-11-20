#!/bin/zsh
# Builds "CVM Control.app" in this folder.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="CVM Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/CVMControl" "$APP/Contents/MacOS/CVMControl"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CVM Control</string>
    <key>CFBundleDisplayName</key><string>CVM Control</string>
    <key>CFBundleIdentifier</key><string>local.cvmcontrol</string>
    <key>CFBundleExecutable</key><string>CVMControl</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>CVM Control connects to the Stewart CVM screen controller on your local network.</string>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP"
echo "Built: $PWD/$APP"
