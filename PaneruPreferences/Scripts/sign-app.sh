#!/bin/zsh
set -eu
setopt extendedglob
cd "${0:A:h}/.."
source Scripts/signing-common.sh
[[ $# -ge 1 ]] || { print -u2 'Usage: sign-app.sh APP [--ad-hoc | --identity SHA1] [--mode default|certificate] [--keychain PATH]'; exit 2; }
paneru_app="${1:A}"; shift
paneru_load_signing
paneru_adhoc=0
while (( $# )); do
    case "$1" in
        --ad-hoc) paneru_adhoc=1; shift ;;
        --identity) [[ $# -ge 2 ]] || exit 2; paneru_identity="$2"; shift 2 ;;
        --mode) [[ $# -ge 2 ]] || exit 2; paneru_mode="$2"; shift 2 ;;
        --keychain) [[ $# -ge 2 ]] || exit 2; paneru_keychain="$2"; shift 2 ;;
        *) print -u2 -- "Unknown signing option: $1"; exit 2 ;;
    esac
done
[[ -d "$paneru_app/Contents" ]] || { paneru_fail 'App bundle does not exist.'; exit 1; }
if (( paneru_adhoc )); then
    print -u2 'Explicit ad-hoc build: macOS permissions may need approval again after code changes.'
    codesign --force --sign - "$paneru_app"
    codesign --verify --strict --all-architectures "$paneru_app"
else
    paneru_validate_signing
    paneru_identity_available
    paneru_sign_bundle "$paneru_app"
fi
