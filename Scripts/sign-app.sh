#!/bin/zsh
set -eu
setopt extendedglob
cd "${0:A:h}/.."
source Scripts/signing-common.sh
[[ $# -ge 1 ]] || { print -u2 'Usage: sign-app.sh APP [--ad-hoc | --identity SHA1] [--mode default|certificate] [--keychain PATH]'; exit 2; }
rd_app="${1:A}"; shift
rd_load_signing
rd_adhoc=0
while (( $# )); do
    case "$1" in
        --ad-hoc) rd_adhoc=1; shift ;;
        --identity) [[ $# -ge 2 ]] || exit 2; rd_identity="$2"; shift 2 ;;
        --mode) [[ $# -ge 2 ]] || exit 2; rd_mode="$2"; shift 2 ;;
        --keychain) [[ $# -ge 2 ]] || exit 2; rd_keychain="$2"; shift 2 ;;
        *) print -u2 -- "Unknown signing option: $1"; exit 2 ;;
    esac
done
[[ -d "$rd_app/Contents" ]] || { rd_fail 'App bundle does not exist.'; exit 1; }
if (( rd_adhoc )); then
    print -u2 'Explicit ad-hoc build: macOS permissions may need approval again after code changes.'
    codesign --force --sign - "$rd_app"
    codesign --verify --strict --all-architectures "$rd_app"
else
    rd_validate_signing
    rd_identity_available
    rd_sign_bundle "$rd_app"
fi
