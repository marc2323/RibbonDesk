# Development guide

[Main README](../README.md) · [Settings guide](../PaneruPreferences/README.md)

## Repository layout

| Path | Contents |
| --- | --- |
| `PaneruPreferences/` | SwiftUI/AppKit companion, overview, click protection, assets, and installer. |
| `PaneruEngine/` | Paneru 0.5.2 with local window-management changes and Bevy regression tests. |
| `PaneruPreferences/paneru-init.lua` | Companion configuration and Control–Option bindings installed as `init.lua`. |
| `.build/` | Ignored binaries, app bundles, test executables, and local release staging. |

The retired RibbonDesk prototype is preserved under the
`ribbondesk-prototype-retired` tag. The current repository name and URL are retained
for existing links. See [upstream provenance](../PaneruEngine/UPSTREAM.md) and
[license notices](../THIRD_PARTY_NOTICES.txt).

## Build from source

Requires macOS 13+, Apple’s command-line developer tools, and Rust 1.95.0 with
Clippy and rustfmt. The engine’s [toolchain file](../PaneruEngine/rust-toolchain.toml)
pins that version.

For a Homebrew rustup installation, run these commands from the repository root:

```sh
brew install rustup
/opt/homebrew/opt/rustup/bin/rustup toolchain install 1.95.0 --profile minimal --component rustfmt --component clippy
zsh PaneruPreferences/install.sh
```

The source installer builds both components, stops the companion before the
engine so Desktop policy cannot relaunch the old helper, then installs
`~/Applications/RibbonDesk.app`. It backs up the Lua configuration and
preserves saved preferences. It also migrates the old `Paneru Settings.app` into
the backup directory with a `.backup` suffix. Open the installed app to start
the companion and engine, and complete the normal macOS Accessibility setup.

To build without installing:

```sh
zsh PaneruEngine/build.sh
zsh PaneruPreferences/build.sh
```

The app bundle is written to `.build/paneru-preferences/RibbonDesk.app`.
The build targets the current Mac’s architecture; the published binary is
arm64. Use the [release download](https://github.com/marc2323/RibbonDesk/releases/latest)
for the prebuilt app and installer.

To package a built, signed app from a clean commit:

```sh
zsh PaneruPreferences/Scripts/package-release.sh
```

This writes the versioned RibbonDesk ZIP, build manifest, and checksums under
`.build/releases/`. The packaged `Install.command` and source installer share
[the same installation script](../PaneruPreferences/Scripts/install-app.sh).
After building, verify fresh installs and upgrades without changing your app:

```sh
python3 PaneruPreferences/Tests/test_install.py
```

### Build storage

Cargo commands run from the repository root or a subdirectory use
`.build/paneru-engine`, configured in `.cargo/config.toml`. Builds, Clippy,
engine tests, and vendored transport tests reuse this location. The engine build
script also sets this path when invoked from outside the repository. Avoid
separate target directories for individual checks or review copies.

Development, test, and fast-release profiles disable incremental compilation
and retain only filename/line debug information for backtraces. This limits
compiler output, at the cost of slower rebuilds of changed Rust code and reduced
variable inspection in a debugger. Compiled dependencies are still cached.
For a debugging task that needs full information, temporarily add
`--config 'profile.dev.debug=2'` to the relevant Cargo command (or use
`profile.test` / `profile.fast-release` for those profiles).

Source snapshots should exclude verified generated caches and dependency
installations. Keep source, vendored code, fixtures, lockfiles, release packages,
and rollback builds. Do not delete the whole `.build` folder for routine cache
maintenance: it also contains app bundles, releases, and recovery artifacts.

### Local signing

The build retains the configured signing identity from
`~/Library/Application Support/local.paneru.preferences/development-signing.plist`.
The signing helpers are in [PaneruPreferences/Scripts](../PaneruPreferences/Scripts).
If no signing configuration exists, the ordinary build uses ad-hoc signing.

The published app is signed with a local development certificate and is
not Apple-notarized. Signing keys are kept outside this repository. Build and
installation scripts do not edit macOS trust, quarantine, or permission databases.

## Runtime and configuration

| Location | Purpose |
| --- | --- |
| `~/Applications/RibbonDesk.app` | Installed companion. |
| `Contents/MacOS/paneru` inside the app | Bundled engine; the Homebrew executable remains a fallback. |
| `~/.config/paneru/preferences.json` | Saved UI preferences. |
| `~/.config/paneru/preferences.lua` | Preferences exported for the engine configuration. |
| `~/.config/paneru/init.lua` | Installed companion configuration. |
| `~/.config/paneru/scroll-presets.json` | Saved feel presets. |
| `~/.config/paneru/app-behavior.json` | App choices and the last 200 behavior log entries. |
| `~/.config/paneru/app-behavior.lua` | App rules exported for new-window placement. |
| `~/.config/paneru/backups/` | Installer backups. |
| `~/Library/Logs/Paneru` | Engine output and error logs. |

The visible app and engine names are RibbonDesk. Bundle/signing identifiers,
IPC names, and the existing `paneru` storage paths remain stable for upgrades.
The engine remains named `paneru` on disk for CLI compatibility. macOS may cache
an older permission entry’s name until it refreshes; installers do not reset grants.

The companion starts one engine through the on-demand LaunchAgent
`com.github.karinushka.paneru`. Login registration belongs to the companion;
disabling it leaves the current session running. Login launches stay in the menu bar.

Preference edits are coalesced about every 80 ms. Scrolling, focus, and outline
changes reload configuration. A gap change or Desktop-policy change refreshes
the layout; login-only changes do not restart the engine. Overview animation
persists separately from feel presets and never reloads the engine.

Width calibration runs for new windows and explicit gap refreshes. Ordinary
hover or activation never resizes columns. Desktop exclusions follow stable
Space identities and are also checked at native input time during transitions.

## Implementation notes

### Experimental magnetic snapping

The `codex/magnetic-snapping` branch adds an opt-in **Magnetic snapping** toggle
under Snapping (development app v1.21, build 24). It replaces the one-page cap
and projected flick destination with local capture at both column edges. Finger
motion stays direct; after release, speed and distance determine whether an edge
catches or motion coasts through. All column widths participate, including apps
with minimum sizes. Overview retains its existing free panning.

Start with magnet strength 1.8 screens/second, range 20%, momentum 1× and decay 4.
Strength controls capture speed; range controls placement tolerance. Lower
strength or higher momentum makes skipping easier. Saved feel presets include
the mode and both magnet controls. Turning the mode off restores the saved
paging/classic settings; it does not reset other tuning sliders.

The selector borrows column geometry without allocating or querying macOS, exits
early above the maximum capture speed, and reuses the existing critically damped
spring. A swept-segment check protects narrow magnets at lower frame rates.
The existing scroll component and event loop own motion and are idle at rest.
Regression tests cover medium/fast flicks with paging enabled, both directions,
precise drags, strength/range/momentum changes, arbitrary column widths, missing
wheel phases, touch/keyboard interruption and both sides of the infinite seam.
Physical trackpad feel still needs user tuning.

### Viewport and focus

A per-workspace `ScrollPositionHold` preserves the viewport through hover,
repeated focus notifications, activation, and ordinary clicks. Command-click
releases the hold for the clicked workspace on mouse-up and reveals the window.
Explicit navigation and arrangement hotkeys also reveal their target and stop
an active coast. Modifier scrolling consumes the native momentum tail once.

The active-window outline is hidden through motion and returns after 150 ms
without movement. The quiet period uses the existing event loop. The outline
ignores mouse input and remains hidden in Mission Control, native fullscreen,
and overview. Rendering reuses a display-clipped overlay per touched display.

### Overview and capture

The companion uses the engine’s logical ribbon coordinates rather than parked
native frames. A single camera preserves order, sizes, gaps, and vertical stacks
at one-third scale, with a height fallback for unusually short displays.
Viewport culling and geometry-only subscription refreshes bound layout work.
J/K repeat steps are serialized against fresh engine order and move whole columns.

On macOS 14+, ScreenCaptureKit takes one-shot screenshots. On macOS 13, a temporary
stream stops after one complete frame or a one-second timeout. Only visible
windows and a small margin are requested, with two captures in flight. A 64 MiB
decoded-image LRU cache supplies warm previews. Distant, evicted previews can
be captured again when revisited. Previews freeze until reopening or recapture;
stale sessions cannot deliver results after closing. No audio or files are
recorded, and no capture or polling runs while overview is closed.

Raw three-finger Overview input includes ordered begin/move/end/cancel boundaries.
The companion filters release velocity and integrates a continuous exponential
coast at the display rate (up to 120 Hz). Its timer exists only during coasting
and is invalidated at rest, a bounded edge, new input, navigation, dragging,
handoff, or close. Native wheel momentum remains owned by its original path.
Overview geometry is cached until the window records change, and preview requests
are replaced only when the visible ID set changes or the user requests capture.

The starting-window ID is captured once per Overview session from exact native
focus, with a legacy focus/visibility fallback. The opening camera centers that
window's logical midpoint rather than the native viewport midpoint. Bounded
ribbons retain end padding so their first and last windows can also be centered.
A small static light-blue arrow points at the top center of the starting preview
in screen coordinates. It does not intercept input or schedule frames. Repeated
previews share one landmark nearest the viewport center; a removed origin is
never reassigned to another window.

Click, swipe, and Return entry keep the covering panel until the engine confirms
the exact native focused window and reads back its final geometry. Native
readiness and the optional 160 ms animation may complete in either order. The
companion then releases hover and normal ribbon input. Close/quit confirmation
recovery uses a bounded fallback, since a modal sheet can own native focus
instead of its parent; normal entry retains the strict readiness gate.

The engine intercepts both raw touch events and WindowServer’s separate Dock
control stream: event 30, dock-swipe subtype 23, vertical axis 2. It owns the
complete three-finger vertical sequence, including end packets after raw finger
lift, so native Mission Control does not take over. Keyboard/hot-corner Mission
Control remains native. Paused management and excluded Desktops bypass the
override; horizontal paging keeps its original path.

See the [overview protocol](../PaneruEngine/CONFIGURATION.md#companion-ribbon-overview),
[query format](../PaneruEngine/QUERY_AND_SUBSCRIBE_FORMAT.md), and
[Lua scripting guide](../PaneruEngine/SCRIPTING.md).

### App Behavior

The companion configuration enables `default_floating` while leaving the
engine's standalone default unchanged. New floating windows skip width and gap
normalization; explicit Control–Option–T or a prompt's exact-window command adds
them to the Ribbon and applies gaps. App rules are keyed by bundle ID and apply
to future windows. Saved sessions take precedence and retain Ribbon gaps.

App Behavior saves a private JSON catalog and escaped Lua export. History is
bounded at 200 entries. History-only updates do not reload the engine. Prompt
choices remember an app only when the checkbox is selected; ordinary hotkey
actions affect one window. Closing/minimizing a window, switching Desktops, or
pausing/restarting management dismisses pending prompts. Exact-window actions
validate the owner PID, standard role, current workspace, and hidden/minimized
state before changing membership. A filtered IPC subscription receives lifecycle
and explicit membership events without extracting layout on hover or focus.
Reconnection checks launchd state to preserve manual keyboard pauses.

### Logs, IPC, and idle work

Log directories use mode `0700`; files use `0600`. Both launch paths refuse
symlinks, hard links, and non-regular log files. Legacy generated `/tmp` paths
migrate on the next engine start. Window-rule comments flatten control
characters from application metadata.

IPC uses the existing Mach service and MessagePack protocol, with backpressure
at 64 pending operations, 64 live subscriptions, and 4,096 operations per layout
batch. Payloads above 4 MiB are rejected before copying. Replies are one-shot
and nonblocking; native input admission is independent of IPC admission.
See the [local transport changes](../PaneruEngine/vendor/async-mach-ports/LOCAL_CHANGES.md).

Native-tab recovery checks ECS geometry before native queries. Configuration
getters avoid whole-options copies. Framework symbols and display mappings
are cached, while live Space policy is read at input time. Subprocess workers
grow on demand to the existing maximum and retire after 30 seconds idle.

Wake, screen wake, session activation, and screen unlock schedule gesture
recovery after a 750 ms quiet period. Recovery waits until the user's session
is on the console and unlocked, then gracefully restarts a running engine using
the existing layout save/restore path. It respects manual pauses and Desktop
exclusions, and serializes with preference updates and other engine operations.
Repeated notifications coalesce; ordinary application/Desktop refreshes do not
restart the engine.

A real sleep/unlock check showed that macOS could stop delivering trackpad
gestures while keyboard shortcuts and both native event taps remained enabled.
Replacing the taps did not restore gestures; a full process restart did. This
is why recovery relaunches the engine instead of relying on tap health checks.

The change passed the 478 engine tests, strict Clippy, formatting, companion
policy/preference tests, and a warnings-as-errors Swift build. A native smoke
check confirmed that duplicate unlock notifications cause one engine relaunch
while the companion stays running and window order, focus, preferences, and
feel presets are preserved. Installed signing requirements remain unchanged.
The user confirmed gestures recover automatically after closing the lid,
reopening the laptop, and unlocking.

## Validation

Run from the repository root with Rust 1.95.0 available on PATH:

```sh
cargo fmt --manifest-path PaneruEngine/Cargo.toml --check
cargo clippy --manifest-path PaneruEngine/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path PaneruEngine/Cargo.toml --all-targets
```

The Bevy harness uses a mock macOS window manager. It verifies layout, viewport
holds, input ownership, exact-window handoff, column arrangement, close/quit
targeting, and outline behavior without moving desktop windows.

### Companion checks

These tests use fixtures without starting capture or manipulating desktop windows:

```sh
mkdir -p .build
xcrun swiftc -swift-version 5 \
  PaneruPreferences/Sources/RibbonSnapshot.swift \
  PaneruPreferences/Tests/Overview/main.swift -o .build/ribbon-overview-tests
.build/ribbon-overview-tests

xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  PaneruPreferences/Sources/RibbonSnapshot.swift \
  PaneruPreferences/Sources/RibbonPreviewCapture.swift \
  PaneruPreferences/Tests/PreviewCapture/main.swift -o .build/ribbon-preview-tests
.build/ribbon-preview-tests

xcrun swiftc -swift-version 5 \
  PaneruPreferences/Sources/CommandRunner.swift \
  PaneruPreferences/Tests/CommandRunner/main.swift -o .build/command-runner-tests
.build/command-runner-tests

xcrun swiftc \
  PaneruPreferences/Sources/DesktopSpaceSession.swift \
  PaneruPreferences/Sources/Preferences.swift \
  PaneruPreferences/Sources/ScrollPresets.swift \
  PaneruPreferences/Sources/PrivateLogs.swift \
  PaneruPreferences/Tests/main.swift -o .build/desktop-policy-tests
.build/desktop-policy-tests

xcrun swiftc -swift-version 5 \
  PaneruPreferences/Sources/Preferences.swift \
  PaneruPreferences/Sources/PreferencesAutosaver.swift \
  PaneruPreferences/Tests/Autosave/main.swift -o .build/preferences-autosave-tests
.build/preferences-autosave-tests
```

App Behavior persistence and stream checks use isolated temporary files:

```sh
xcrun swiftc -swift-version 5 -warnings-as-errors \
  -module-cache-path .build/paneru-preferences/module-cache \
  PaneruPreferences/Sources/AppBehavior.swift \
  PaneruPreferences/Tests/AppBehavior/main.swift -o .build/app-behavior-tests
.build/app-behavior-tests

xcrun swiftc -swift-version 5 -warnings-as-errors \
  -module-cache-path .build/paneru-preferences/module-cache \
  PaneruPreferences/Sources/AppBehavior.swift \
  PaneruPreferences/Sources/AppBehaviorUI.swift \
  PaneruPreferences/Sources/RibbonSnapshot.swift \
  PaneruPreferences/Tests/AppBehaviorRender/main.swift -o .build/app-behavior-render-tests
.build/app-behavior-render-tests "$PWD/.build"
```

The render harness checks the editor model and writes settings/prompt PNGs
without launching an engine, showing a window, or changing installed preferences.

With Lua installed, check the preferences-to-configuration bridge:

```sh
lua PaneruPreferences/Tests/scroll-config.lua PaneruPreferences/paneru-init.lua
```

The patched transport has a separate suite:

```sh
cargo test --locked --manifest-path PaneruEngine/vendor/async-mach-ports/Cargo.toml --all-targets
```

### Release validation record

**v1.20 (build 23)** adds the optional Infinite ribbon setting in normal and
Overview modes. Overview supports two- and three-finger scrolling, with smooth
three-finger momentum. Opening Overview centers the original window, including
the first and last windows of bounded ribbons, and marks its top center with a
small light-blue arrow. The release also includes the App Behavior changes below.

Validation covers 498 engine tests, strict Clippy and formatting,
warnings-as-errors Swift compilation, companion policy/preference/autosave and
command-runner checks, App Behavior persistence/model checks, Overview camera
and momentum checks, preview capture, the Lua configuration bridge, and six
isolated installer tests. Native checks confirmed centering and the arrow,
preserved settings and window order, and deep/strict app signature verification.
Release packaging records the merged source commit and binary hashes in
`BUILD-INFO.json`, with checksums for the ZIP and manifest.

**Local v1.20 (build 22)** adds floating-by-default new windows, the existing
Control–Option–T admission toggle, remembered app choices, optional prompts, and
the App Behavior editor with a 200-entry log. It passed 484 Rust tests, strict
Clippy and formatting, warnings-as-errors Swift compilation, companion
policy/preference/autosave checks, App Behavior persistence/model checks, the Lua
configuration bridge, and six isolated installer tests. Offscreen renders cover
the editor and prompt; window-management behavior was exercised through the
mock harness rather than live desktop manipulation. The signed app passed native deep/strict signature
verification. Installer checks include preservation and backups of the app
catalog and Lua export. The build was subsequently installed and launched locally;
verification confirmed the previous app/configuration backup, unchanged existing
preferences and feel presets, one running companion, a ready engine, and preserved
Ribbon window order.

Storage cleanup retained the canonical Cargo output and primary Swift module
cache for reuse. No disposable compiler-cache directories, browser profiles,
Python environments, or JavaScript dependency installs were created; no folders
were removed and no space was reclaimed. Test fixture stores clean themselves
up, and screenshots, test logs, source, and the built app are retained.

**v1.19 (build 21)** displays the app's version and build number in the Settings
header, using bundle metadata and an accessibility label. The display was
verified in the installed app. The release build passed warnings-as-errors
Swift compilation, companion policy/preference tests, and six isolated
installer checks. App and engine signing requirements match v1.18.

**v1.18 (build 19)** restores touchpad gestures after sleep and unlock by
restarting the engine once the unlocked session settles. It preserves manual
pauses, Desktop exclusions, window order, focus, preferences, and feel presets.
The fix passed 478 engine tests, strict Clippy and formatting, native recovery
checks, and a confirmed physical lid-close/unlock cycle. The release build
passed warnings-as-errors Swift compilation, companion policy/preference tests,
and six isolated installer checks. App and engine signing requirements match
v1.17.

**v1.17 (build 18)** retains the v1.16 window-management behavior and renames the
installed app, interface, and embedded engine metadata to RibbonDesk. It passed
478 Rust tests, strict Clippy and formatting, Swift warnings-as-errors compilation,
command-runner and preference/preset checks, and six isolated installer checks.
The latter cover fresh installs, legacy/mixed upgrades, app/configuration backups,
settings preservation, and refusal to replace unrelated apps.

Native checks confirmed both running processes report RibbonDesk, the engine runs
from the new app path, and the app appears as RibbonDesk in Accessibility, Screen
Recording, and Open at Login. Existing grants, login registration, saved settings,
and window order survived the rename. Certificate-bound requirements for the app
and engine match the previous build. Permission grants were not reset.

The published **v1.16 (build 17)** passed **478 Rust tests**, strict Clippy,
formatting, Swift regression checks, a warnings-as-errors companion build, and
offscreen rendering. Native checks covered keyboard arrangement, cursor-based
entry, targeted close through the button/Command–W/context menu, graceful quit
through Command–Q/the Quit button, and simulated save-confirmation cancellation.
Close/quit checks used only the disposable
[OverviewActionsFixture](../PaneruPreferences/Tests/OverviewActionsFixture/main.swift).
Window order/focus and preferences were restored afterward.

The release package passed isolated fresh-install and upgrade checks, including
backups and settings preservation. Downloaded assets were checked against their
SHA-256 checksums, binary/configuration manifest, and code signatures.

Earlier native checks covered starting from a stopped session, login-item
registration without logging out, compact Settings layout, and preservation of
saved preferences. Revision 1.15 passed 476 Rust tests and native J/K and
cursor-entry checks. Its accept command exercised the downward-swipe companion
path; a physical trackpad gesture was not synthesized by the test tools.
