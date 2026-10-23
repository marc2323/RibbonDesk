#!/bin/zsh
set -euo pipefail
project="${0:A:h}"
workspace="${project:h}"
output="$workspace/.build/paneru-preferences"
app="$output/Paneru Settings.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$output/module-cache"
engine="$workspace/.build/paneru-engine/fast-release/paneru"
[[ -x "$engine" ]] || { print -u2 'Build the engine first with PaneruEngine/build.sh.'; exit 1; }
cp "$engine" "$app/Contents/MacOS/paneru"
xcrun swiftc -swift-version 5 -O -module-cache-path "$output/module-cache" \
    "$project"/Sources/*.swift -o "$app/Contents/MacOS/PaneruSettings"
python3 - "$app" <<'PY'
import plistlib,sys,pathlib
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
p.write_bytes(plistlib.dumps({
 'CFBundleIdentifier':'local.paneru.preferences',
 'CFBundleName':'Paneru Settings','CFBundleDisplayName':'Paneru Settings',
 'CFBundleExecutable':'PaneruSettings','CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':'1.10','CFBundleVersion':'11',
 'LSUIElement':True,'LSMinimumSystemVersion':'13.0',
 'CFBundleIconFile':'Paneru.icns','NSHighResolutionCapable':True,
 'NSHumanReadableCopyright':'Local Paneru preferences companion. Paneru engine by its contributors.'
}))
PY
"$app/Contents/MacOS/PaneruSettings" --render-assets "$project/Assets"
/usr/bin/iconutil -c icns "$project/Assets/Paneru.iconset" -o "$app/Contents/Resources/Paneru.icns"
signing="$HOME/Library/Application Support/local.paneru.preferences/development-signing.plist"
if [[ -f "$signing" ]]; then
    identity=$(/usr/libexec/PlistBuddy -c 'Print :Identity' "$signing")
    mode=$(/usr/libexec/PlistBuddy -c 'Print :RequirementMode' "$signing")
    /usr/bin/codesign --force --sign "$identity" --identifier local.paneru.engine "$app/Contents/MacOS/paneru"
    zsh "$project/Scripts/sign-app.sh" "$app" --identity "$identity" --mode "$mode"
else
    /usr/bin/codesign --force --sign - "$app/Contents/MacOS/paneru"
    /usr/bin/codesign --force --sign - "$app"
fi
/usr/bin/codesign --verify --strict "$app"
print -r -- "$app"
