#!/bin/zsh
set -euo pipefail
project="${0:A:h}"
workspace="${project:h}"
output="$workspace/.build/paneru-preferences"
app="$output/Paneru Settings.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$output/module-cache"
xcrun swiftc -swift-version 5 -O -module-cache-path "$output/module-cache" \
    "$project"/Sources/*.swift -o "$app/Contents/MacOS/PaneruSettings"
python3 - "$app" <<'PY'
import plistlib,sys,pathlib
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
p.write_bytes(plistlib.dumps({
 'CFBundleIdentifier':'local.paneru.preferences',
 'CFBundleName':'Paneru Settings','CFBundleDisplayName':'Paneru Settings',
 'CFBundleExecutable':'PaneruSettings','CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':'1.2','CFBundleVersion':'3',
 'LSUIElement':True,'LSMinimumSystemVersion':'13.0',
 'CFBundleIconFile':'Paneru.icns','NSHighResolutionCapable':True,
 'NSHumanReadableCopyright':'Local Paneru preferences companion. Paneru engine by its contributors.'
}))
PY
"$app/Contents/MacOS/PaneruSettings" --render-assets "$project/Assets"
/usr/bin/iconutil -c icns "$project/Assets/Paneru.iconset" -o "$app/Contents/Resources/Paneru.icns"
signing="$HOME/Library/Application Support/local.prototype.RibbonDesk/development-signing.plist"
if [[ -f "$signing" ]]; then
    identity=$(/usr/libexec/PlistBuddy -c 'Print :Identity' "$signing")
    mode=$(/usr/libexec/PlistBuddy -c 'Print :RequirementMode' "$signing")
    zsh "$workspace/Scripts/sign-app.sh" "$app" --identity "$identity" --mode "$mode"
else
    /usr/bin/codesign --force --sign - "$app"
fi
/usr/bin/codesign --verify --strict "$app"
print -r -- "$app"
