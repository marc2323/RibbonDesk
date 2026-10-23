#!/bin/zsh
# Package an already-built, signed app from a clean source commit.
set -euo pipefail
workspace="${0:A:h:h:h}"
cd "$workspace"
git diff --quiet && git diff --cached --quiet || { print -u2 'Commit the release sources before packaging.'; exit 1; }
app="$workspace/.build/paneru-preferences/RibbonDesk.app"
/usr/bin/codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
output="$workspace/.build/releases/v$version"
package="$output/RibbonDesk-$version-macos-$(uname -m)"
[[ ! -e "$package" && ! -e "$package.zip" ]] || { print -u2 'The release package already exists.'; exit 1; }
mkdir -p "$package"
ditto "$app" "$package/RibbonDesk.app"
cp PaneruPreferences/Scripts/install-app.sh "$package/Install.command"
chmod +x "$package/Install.command"
cp PaneruPreferences/paneru-init.lua "$package/"
mkdir -p "$package/Licenses"
cp THIRD_PARTY_NOTICES.txt "$package/Licenses/"
cp PaneruEngine/LICENSE.txt "$package/Licenses/Paneru-MIT.txt"
cp PaneruEngine/vendor/async-mach-ports/LICENSE "$package/Licenses/async-mach-ports-MIT.txt"
python3 - "$package" <<'PY'
import hashlib, json, pathlib, plistlib, subprocess, sys
package = pathlib.Path(sys.argv[1])
app = package / 'RibbonDesk.app'
plist = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
signature = subprocess.run(['codesign', '-dv', str(app)], capture_output=True, text=True, check=True).stderr
manifest = {
    'product': 'RibbonDesk', 'release': 'v' + plist['CFBundleShortVersionString'],
    'app_version': plist['CFBundleShortVersionString'], 'bundle_build': plist['CFBundleVersion'],
    'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'architecture': subprocess.check_output(['uname', '-m'], text=True).strip(),
    'minimum_macos': plist['LSMinimumSystemVersion'], 'apple_notarized': False,
    'engine_version': '0.5.2 with local changes',
    'signing_authority': next((line.removeprefix('Authority=') for line in signature.splitlines() if line.startswith('Authority=')), 'ad-hoc'),
    'sha256_binaries': {name: sha(app / 'Contents/MacOS' / name) for name in ['RibbonDesk', 'paneru']},
    'sha256_configuration': sha(package / 'paneru-init.lua'),
    'sha256_installer': sha(package / 'Install.command'),
}
(package / 'BUILD-INFO.json').write_text(json.dumps(manifest, indent=2) + '\n')
(package / 'README.txt').write_text(
    f"RibbonDesk {plist['CFBundleShortVersionString']}\n\n"
    'Quit RibbonDesk (or the old Paneru Settings app), then open Install.command.\n'
    'Keep the installer, app, and paneru-init.lua together. The installer backs up\n'
    'the previous app and configuration and preserves preferences and feel presets.\n'
    'Then open ~/Applications/RibbonDesk.app.\n\n'
    'Requires macOS 13 or later. This build is locally signed and not Apple-notarized.\n'
    'macOS may require manual approval before opening a downloaded copy.\n'
    'Allow Accessibility for window management and Screen Recording for overview previews.\n'
    'https://github.com/marc2323/RibbonDesk\n'
)
PY
ditto -c -k --sequesterRsrc --keepParent "$package" "$package.zip"
cp "$package/BUILD-INFO.json" "$output/BUILD-INFO.json"
cd "$output"
shasum -a 256 "${package:t}.zip" BUILD-INFO.json > SHA256SUMS.txt
print -r -- "$package.zip"
