#!/bin/zsh
set -eu
setopt extendedglob
cd "${0:A:h}/.."
source Scripts/signing-common.sh
# Saves only a public fingerprint and selectors. Never creates/imports an
# identity, unlocks a keychain, or changes certificate/private-key trust.
rd_load_signing
while (( $# )); do
    case "$1" in
        --identity) [[ $# -ge 2 ]] || exit 2; rd_identity="$2"; shift 2 ;;
        --mode) [[ $# -ge 2 ]] || exit 2; rd_mode="$2"; shift 2 ;;
        --keychain) [[ $# -ge 2 ]] || exit 2; rd_keychain="$2"; shift 2 ;;
        *) print -u2 'Usage: configure-signing.sh --identity SHA1 [--mode default|certificate] [--keychain PATH]'; exit 2 ;;
    esac
done
rd_validate_signing
rd_identity_available
umask 077
mkdir -p "${rd_config:h}"
rd_config_stage=$(mktemp "${rd_config:h}/.signing-config.XXXXXX")
trap 'rm -f "$rd_config_stage"' EXIT
plutil -create xml1 "$rd_config_stage"
plutil -insert Identity -string "$rd_identity" "$rd_config_stage"
plutil -insert RequirementMode -string "$rd_mode" "$rd_config_stage"
plutil -insert Keychain -string "$rd_keychain" "$rd_config_stage"
chmod 600 "$rd_config_stage"
mv -f "$rd_config_stage" "$rd_config"
print -r -- "Saved public signing selection to $rd_config"
print 'No code was signed. Verify two changed fixture builds before migrating Accessibility approval.'
