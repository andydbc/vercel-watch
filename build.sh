#!/bin/bash
# Calls Xcode's swiftc directly (no SwiftPM needed).
set -e
cd "$(dirname "$0")"
X=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
APP=VercelWatch.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp Resources/AppIcon.icns $APP/Contents/Resources/
$X/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc \
  -sdk $X/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  -O -parse-as-library Sources/VercelWatch/VercelWatchApp.swift \
  -o $APP/Contents/MacOS/VercelWatch
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.vercelwatch</string>
<key>CFBundleName</key><string>VercelWatch</string>
<key>CFBundleExecutable</key><string>VercelWatch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
codesign --force --sign - $APP
echo "Built $APP — run: open $APP"
