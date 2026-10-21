#!/bin/zsh
set -eu
setopt extendedglob
cd "${0:A:h}/.."
source Scripts/signing-common.sh
rd_changed=0
if [[ "${1:-}" == --require-changed-code ]]; then rd_changed=1; shift; fi
[[ $# -eq 2 ]] || { print -u2 'Usage: check-signing-continuity.sh [--require-changed-code] OLD_APP NEW_APP'; exit 2; }
rd_old="${1:A}"; rd_new="${2:A}"
for rd_app in "$rd_old" "$rd_new"; do codesign --verify --strict --all-architectures "$rd_app"; done
[[ "$(rd_bundle_id "$rd_old")" == "$(rd_bundle_id "$rd_new")" ]] || { rd_fail 'Bundle identifiers differ.'; exit 1; }
rd_old_leaf=$(rd_leaf_hash "$rd_old") || { rd_fail 'Previous build is not certificate-signed.'; exit 1; }
rd_new_leaf=$(rd_leaf_hash "$rd_new") || { rd_fail 'New build is not certificate-signed.'; exit 1; }
[[ "$rd_old_leaf" == "$rd_new_leaf" ]] || { rd_fail 'Signing certificates differ; explicit migration is required.'; exit 1; }
rd_old_requirement=$(rd_requirement "$rd_old")
rd_new_requirement=$(rd_requirement "$rd_new")
[[ "$rd_old_requirement" == "$rd_new_requirement" ]] && rd_stable_requirement "$rd_old_requirement" || {
    rd_fail 'Designated requirements differ or depend on the binary hash.'; exit 1;
}
codesign --verify --strict --all-architectures -R "=$rd_old_requirement" "$rd_new"
codesign --verify --strict --all-architectures -R "=$rd_new_requirement" "$rd_old"
if (( rd_changed )); then
    rd_old_cdhash=$(codesign --display --verbose=4 "$rd_old" 2>&1 | sed -n 's/^CDHash=//p')
    rd_new_cdhash=$(codesign --display --verbose=4 "$rd_new" 2>&1 | sed -n 's/^CDHash=//p')
    [[ -n "$rd_old_cdhash" && -n "$rd_new_cdhash" && "$rd_old_cdhash" != "$rd_new_cdhash" ]] || {
        rd_fail 'The two executable code hashes did not change.'; exit 1;
    }
fi
print -r -- "PASS signing continuity: same certificate $rd_old_leaf, same designated requirement, both cross-checks satisfied."
