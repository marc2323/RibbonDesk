# Stable local development signing

RibbonDesk's previous `codesign --sign -` builds used ad-hoc identities tied to
one code version. Apple explains that macOS records designated requirements to
recognize later versions for privacy authorization; ad-hoc requirements cannot
provide that continuity. A native 0.11.0 build 11 → build 12 update has now
retained Accessibility approval with the selected certificate and requirement.
[Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

## One-time human setup

Preferred: create/select an **Apple Development** identity in Xcode Settings →
Accounts → Manage Certificates. Keep its certificate and private key in your
keychain. RibbonDesk retains `codesign`'s generated designated requirement.
[Apple: Manage signing certificates](https://help.apple.com/xcode/mac/current/#/dev154b28f09)

For development confined to this Mac, the alternative is Keychain Access →
Certificate Assistant → Create a Certificate: name **RibbonDesk Local
Development**, identity type **Self Signed Root**, certificate type **Code
Signing**. Keep the private key on this Mac; do not export it into the project.
Apple documents this local development route and certificate-leaf requirements.
[Apple: Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)

Leave certificate trust at its defaults. A certificate-leaf designated
requirement authenticates the exact signing certificate without an `anchor
trusted` term; Apple's requirement-language documentation says trust settings
are consulted only for requirements using `trusted`. No Always Trust certificate
setting or system root installation is required. The scripts do not
programmatically modify certificate trust, private-key access controls, or TCC
entries. Signing and strict verification of the selected local identity have
succeeded with certificate trust left at its defaults. If a later check fails,
inspect the error before changing trust.
[Apple: Requirement language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html)

Inspect public fingerprints with:

```sh
security find-identity -p codesigning
```

Save the chosen **40-character certificate SHA-1 fingerprint**. For Apple
Development:

```sh
zsh Scripts/configure-signing.sh --identity YOUR_40_HEX_FINGERPRINT --mode default
```

For the local self-signed identity:

```sh
zsh Scripts/configure-signing.sh --identity YOUR_40_HEX_FINGERPRINT --mode certificate
```

The command saves only the public fingerprint, requirement mode, and optional
keychain selector in `~/Library/Application Support/local.prototype.RibbonDesk/
development-signing.plist`, mode 0600. It is outside source packages. Subsequent
builds load it automatically. It never creates/imports keys, unlocks keychains,
or changes trust. A macOS signing dialog separately asks the human to authorize
Apple's `codesign` tool to use the selected private key. During native setup,
the user explicitly chose **Always Allow**, remembering that limited tool/key
authorization. Certificate trust remains at its defaults.

## Verification before migration

```sh
python3 Tests/SigningChecks.py
zsh Scripts/test-signing-identity.sh
```

The Python checks mock `security` and `codesign`; they exercise persistence,
selection, failure paths, exact certificate requirements, and continuity checks
without accessing keys. The second command requires the existing selected
identity. It compiles and signs two changed, disposable fixtures, never launches
them, and verifies equal signer fingerprints and designated requirements plus
both cross-requirement checks. Their CDHashes must differ. It does not establish
Accessibility permission persistence by itself.

Stage a review build without replacing the running app:

```sh
zsh Scripts/build-app.sh --output "$PWD/.build/review/RibbonDesk.app"
```

After reviewing, pause/restore the running app before deploying to its usual
path. Migration from the old ad-hoc identity may need **one new Accessibility
approval**. Then keep the selected identity and generated requirement stable.
The native 0.11.0 build 11 → build 12 test used changed executable code with the
same signing certificate and designated requirement. Build 12 entered a live
session without a new permission prompt or Settings refresh. All six original
window frames were restored, with zero pending restores. This verifies that
specific update on this Mac; it does not guarantee continuity for every future
certificate, requirement, app-path, or macOS change.

Missing/unavailable identities fail clearly. Disposable builds require explicit
`--ad-hoc`; certificate-signed output cannot silently downgrade. Changing a
certificate or requirement requires reviewed migration and the explicit
`--allow-signing-identity-change` option, or a separate `--output` path. Certificate
renewal, expiry, revocation, and developer-signing-channel changes require review.
This local workflow does not provide notarization or distribution approval.
