#!/bin/zsh
set -eu
setopt extendedglob
cd "${0:A:h}/.."
source Scripts/signing-common.sh
rd_load_signing
preview=0; rd_adhoc=0; rd_allow_identity_change=0; output_override=""
while (( $# )); do
    case "$1" in
        --preview) preview=1; shift ;;
        --ad-hoc) rd_adhoc=1; shift ;;
        --signing-identity) [[ $# -ge 2 ]] || exit 2; rd_identity="$2"; shift 2 ;;
        --signing-mode) [[ $# -ge 2 ]] || exit 2; rd_mode="$2"; shift 2 ;;
        --signing-keychain) [[ $# -ge 2 ]] || exit 2; rd_keychain="$2"; shift 2 ;;
        --allow-signing-identity-change) rd_allow_identity_change=1; shift ;;
        --output) [[ $# -ge 2 ]] || exit 2; output_override="${2:A}"; shift 2 ;;
        *) print -u2 'Usage: build-app.sh [--preview] [--ad-hoc | --signing-identity SHA1] [--signing-mode default|certificate] [--signing-keychain PATH] [--output APP] [--allow-signing-identity-change]'; exit 2 ;;
    esac
done
# Previews have a separate identity, so Launch Services cannot confuse them with
# the delivered app. Build a fresh inode instead of overwriting signed code.
if (( preview )); then app_path="$PWD/dist/trackpad-preview/RibbonDeskPreview.app"
else app_path="$PWD/dist/RibbonDesk.app"; fi
[[ -z "$output_override" ]] || app_path="$output_override"
[[ "$app_path" == *.app ]] || { rd_fail 'Output must be an .app bundle path.'; exit 2; }
rd_previous_leaf=""
[[ ! -d "$app_path" ]] || rd_previous_leaf=$(rd_leaf_hash "$app_path") || true
if (( rd_adhoc )); then
    [[ -z "$rd_previous_leaf" ]] || { rd_fail 'Refusing to replace a certificate-signed app with an ad-hoc build. Use a separate --output path.'; exit 1; }
else
    rd_validate_signing
    rd_identity_available
    if [[ -n "$rd_previous_leaf" && "$rd_previous_leaf" != "$rd_identity" ]] && (( ! rd_allow_identity_change )); then
        rd_fail 'The previous app uses another certificate. Review migration and explicitly use --allow-signing-identity-change or a separate --output path.'; exit 1
    fi
fi
# Local build only. No dependency downloads, installs, permissions, or launch.
zsh Scripts/swift-local.sh build -c release --product RibbonDesk
stage_dir=$(mktemp -d "$PWD/.build/app-stage.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT
staged_app="$stage_dir/${app_path:t}"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp .build/release/RibbonDesk "$staged_app/Contents/MacOS/RibbonDesk"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.txt "$staged_app/Contents/Resources/THIRD_PARTY_NOTICES.txt"
if (( preview )); then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.prototype.RibbonDesk.preview' "$staged_app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName RibbonDesk Preview' "$staged_app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName RibbonDesk Preview' "$staged_app/Contents/Info.plist"
fi
printf 'APPL????' > "$staged_app/Contents/PkgInfo"
if (( rd_adhoc )); then
    zsh Scripts/sign-app.sh "$staged_app" --ad-hoc
else
    signing_args=(--identity "$rd_identity" --mode "$rd_mode")
    [[ -z "$rd_keychain" ]] || signing_args+=(--keychain "$rd_keychain")
    zsh Scripts/sign-app.sh "$staged_app" "${signing_args[@]}"
    if [[ -n "$rd_previous_leaf" ]] && (( ! rd_allow_identity_change )); then
        zsh Scripts/check-signing-continuity.sh "$app_path" "$staged_app"
    elif [[ -d "$app_path" ]]; then
        print -u2 'Signing identity migration: macOS may require one new Accessibility approval. Existing authorizations were not edited.'
    fi
fi
mkdir -p "${app_path:h}"
# Preserve the preceding bundle in the build scratch directory for rollback.
if [[ -d "$app_path" ]]; then mv "$app_path" "$stage_dir/previous-bundle"; fi
if ! mv "$staged_app" "$app_path"; then
    [[ ! -d "$stage_dir/previous-bundle" ]] || mv "$stage_dir/previous-bundle" "$app_path"
    exit 1
fi
if [[ -d "$stage_dir/previous-bundle" ]]; then
    backup_dir=$(mktemp -d "$PWD/.build/previous-app.XXXXXX")
    mv "$stage_dir/previous-bundle" "$backup_dir/bundle"
fi
printf 'Built (not launched): %s\n' "$app_path"
