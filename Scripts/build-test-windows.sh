#!/bin/zsh
set -eu
cd "${0:A:h}/.."
app_path="$PWD/.build/RibbonDeskTestWindows.app"
mkdir -p "$app_path/Contents/MacOS"
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" \
    Tests/Fixtures/TestWindows.swift -o "$app_path/Contents/MacOS/TestWindows.new"
mv "$app_path/Contents/MacOS/TestWindows.new" "$app_path/Contents/MacOS/TestWindows"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>RibbonDesk Test Windows</string>
<key>CFBundleIdentifier</key><string>local.prototype.RibbonDesk.test-windows</string>
<key>CFBundleExecutable</key><string>TestWindows</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$app_path"
printf 'Built disposable test app: %s\n' "$app_path"
