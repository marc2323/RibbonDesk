#!/bin/zsh
set -eu
setopt extendedglob
cd "${0:A:h}/.."
source Scripts/signing-common.sh
rd_load_signing
rd_validate_signing
rd_identity_available
# Explicit opt-in test of a human-selected EXISTING identity. Two disposable
# executables are compiled and signed, never run or enrolled in Accessibility.
mkdir -p .build
fixture_root=$(mktemp -d "$PWD/.build/signing-identity.XXXXXX")
for revision in 1 2; do
    fixture_app="$fixture_root/Revision$revision.app"
    mkdir -p "$fixture_app/Contents/MacOS"
    print -r -- "int main(void) { return $revision; }" > "$fixture_root/revision$revision.c"
    xcrun clang "$fixture_root/revision$revision.c" -o "$fixture_app/Contents/MacOS/Fixture"
    plutil -create xml1 "$fixture_app/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string local.prototype.RibbonDesk.signing-fixture "$fixture_app/Contents/Info.plist"
    plutil -insert CFBundleExecutable -string Fixture "$fixture_app/Contents/Info.plist"
    signing_args=(--identity "$rd_identity" --mode "$rd_mode")
    [[ -z "$rd_keychain" ]] || signing_args+=(--keychain "$rd_keychain")
    zsh Scripts/sign-app.sh "$fixture_app" "${signing_args[@]}"
done
zsh Scripts/check-signing-continuity.sh --require-changed-code "$fixture_root/Revision1.app" "$fixture_root/Revision2.app"
print -r -- "Certificate continuity artifacts retained at: $fixture_root"
