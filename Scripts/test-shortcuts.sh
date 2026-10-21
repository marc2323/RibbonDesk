#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p .build/shortcut-checks
xcrun swiftc -swift-version 5 -module-name ShortcutSmoke \
    -module-cache-path "$PWD/.build/module-cache" \
    Sources/RibbonDesk/GlobalShortcuts.swift Sources/RibbonDesk/RuntimeDiagnostics.swift \
    Tests/ShortcutChecks.swift Tests/ShortcutSmoke/main.swift \
    -o .build/shortcut-checks/ShortcutSmoke
# Package the exact same AX-free receiver for an unambiguous native app test.
# The bundle defaults to five minutes; the standalone CLI defaults to one.
shortcut_bundle="$PWD/.build/shortcut-checks/ShortcutSmoke.app"
mkdir -p "$shortcut_bundle/Contents/MacOS"
cp -f .build/shortcut-checks/ShortcutSmoke "$shortcut_bundle/Contents/MacOS/ShortcutSmoke"
cat > "$shortcut_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.prototype.RibbonDesk.shortcut-check</string>
    <key>CFBundleExecutable</key><string>ShortcutSmoke</string>
    <key>CFBundleName</key><string>RibbonDesk Keyboard Test</string>
    <key>CFBundleDisplayName</key><string>RibbonDesk Keyboard Test</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.10</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier local.prototype.RibbonDesk.shortcut-check "$shortcut_bundle"
codesign --verify --strict "$shortcut_bundle"
# Unit checks never register real keys. Pass --native explicitly to open a
# Carbon receiver, still disconnected from Accessibility and windows. Optional
# receiver flags include --seconds 300 and --no-window.
if [[ "${1:-}" == "--native" ]]; then
    .build/shortcut-checks/ShortcutSmoke "${@:2}"
else
    .build/shortcut-checks/ShortcutSmoke --unit-only
fi
