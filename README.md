# Paneru with native settings

A compact macOS menu-bar companion and a local build of Paneru 0.5.2. The dropdown
controls activation mode, scroll speed, momentum and its decay, flick-snap thresholds and animation, feel presets,
window gaps, the active window outline,
and launch at login, with the
complete Control–Option shortcut list visible without scrolling. All settings
apply and persist automatically, including slider changes while dragging; there
is no Save step. Pause/Start, Restart, and Quit are in Settings; right-click shows only Quit.

- `PaneruPreferences/`: SwiftUI/AppKit companion, click protection, icons, and installer.
- `PaneruEngine/`: Paneru source with a per-workspace scroll-position hold and regression tests.

Three-finger paging is enabled by default: any horizontal three-finger swipe
advances exactly one window alignment, following the fingers within that
step and finishing at lift. Speed, distance, and free-scroll thresholds cannot
prevent or skip the step. The toggle restores the existing free-scrolling mode,
and Snap animation controls both modes. Modifier scrolling keeps its free-scroll
tuning. Existing feel presets restore their original mode; new presets save the toggle.
Paging includes apps with fixed or minimum widths, such as Tailscale, and can
align either edge of windows that are narrower or wider than the screen.

Scrolling follows the fingers while dragging, then coasts according to release
speed and the Momentum slider. A separate Momentum decay slider controls how
quickly the coast fades, with a 1–100 range; higher values stop sooner. A sufficiently
fast flick that projects far enough into a full- or half-width window finishes by
snapping it into view. Half-width windows can align to either edge. Flick threshold
and Snap visibility tune when snapping starts; Snap animation independently controls
how quickly it settles. Snap back is off by default, so small swipes keep their progress.
Enable it and adjust Exit distance to experiment with resistance when leaving an
aligned window. Named Feel presets save and restore scrolling and snapping together.
Touch again to stop a fling, or pause before lifting to
stop in place. Modifier scrolling consumes the native momentum tail so inertia
is applied once. Once placed, the viewport stays where the
user left it through hover, repeated focus notifications, and application
activation and ordinary clicks. **Command-click a managed window** to snap it
into view on mouse-up with a quick animation (about 150ms). **Previous/Next window
hotkeys always scroll to the selected window**, even after manual scrolling.
**Control–Option–J/K** moves the window left/right and scrolls with it to keep
its new position visible, including after manual scrolling or during a coast.
Hover and ordinary focus notifications keep the manually chosen viewport.

**This Desktop** in the menu-bar settings controls each native macOS
desktop Space separately. Disable it to turn off Paneru's tiling,
gestures, activation, click protection, and hotkeys on that desktop. Switching
back to an enabled desktop resumes Paneru. Re-enable an excluded desktop through
the menu-bar icon; its settings hotkey is also inactive.

## Ribbon overview

Swipe **up with three fingers**, press **Control–Option–O**, or click **Overview**
in Settings while window management is active. The ribbon zooms out as one scene,
preserving its window widths, heights, stacks, gaps and order. The overview uses
one-third scale, with horizontal scrolling for long ribbons. The initial view
stays near the current viewport. Scroll with
two fingers or a mouse wheel, use the bottom track/arrows, or select windows with
the arrow keys. The menu bar remains visible under the existing macOS setting.

Previews are still snapshots. Click a window to zoom into its real position and
resume normal interaction. Swipe **down with three fingers** to enter the window
currently under your cursor (or the selected preview when over the background).
Escape or the background returns to the original viewport. **J/K** moves the
highlighted window left/right while keeping it selected and visible; the usual
Control–Option–J/K shortcuts also work. Arrow keys select a different preview.
Drag onto the left/right half of another window to insert before/after
it. Holding a drag near either screen edge scrolls the overview. Stacks and native
tab groups move together; order changes apply immediately.

**Close Window (⌘W)** and **Quit App (⌘Q)** below the selected preview also work
without entering it; right-click a preview for the same actions. Closing targets
that exact native window. Quitting affects its owning app and its other windows.
Overview stays open as windows disappear and selects a nearby survivor. If an
app keeps the requested window open, overview reveals it after a short wait so
you can handle a save confirmation or cancellation.

Use **Allow Window Previews…** to allow Screen Recording for **Paneru Settings**.
Protected content can remain blank. On macOS 14+ ScreenCaptureKit takes one-shot
screenshots; macOS 13 stops a temporary stream after one frame. Only visible
windows and a small margin are requested, with at most two captures in flight.
Previews freeze until reopening (or reloading a distant, evicted preview).
A 64 MiB memory cache makes repeat opens immediate; cached images may briefly
show the previous snapshot while refreshing. Capture never blocks presentation,
records audio, or writes files. Closing discards pending deliveries. Nothing
captures or polls while closed.

Overview transitions are instant by default. Enable **Overview animation** under
Window management to restore the 160 ms zoom. The choice is saved separately
from scroll feel presets and does not restart or reload the engine. Reduce Motion
also disables the zoom. Viewport culling and geometry-only subscription refreshes
keep layout work bounded as the ribbon grows.

On selection, the opaque overview stays above the desktop while the engine snaps
the ribbon to the selected window. The engine acknowledges the exact native focus
and final position before the companion removes the panel and resumes hover and
normal input. This avoids exposing intermediate windows during the handoff.

The vertical gesture override uses both raw touch input and a separate session
interceptor for WindowServer's Dock-control packets (event 30, dock-swipe subtype
23, vertical axis 2). Owning the complete packet sequence prevents native Mission
Control from taking over after the raw finger events end. Native keyboard/hot
corner Mission Control still works. Paused management and excluded Desktops
bypass the override. Horizontal three-finger paging retains its original path.

## Build and install

Requires macOS 13+, Apple's command-line developer tools, and Rust 1.95.0 with
Clippy and rustfmt. The toolchain is pinned in `PaneruEngine/rust-toolchain.toml`.
For a Homebrew rustup installation:

```sh
brew install rustup
/opt/homebrew/opt/rustup/bin/rustup toolchain install 1.95.0 --profile minimal --component rustfmt --component clippy
zsh PaneruPreferences/install.sh
```

The installer builds both components, stops the previous engine, installs
`~/Applications/Paneru Settings.app`, and backs up the existing Lua configuration
before updating it. It preserves saved preferences. Open the installed app to
start the menu-bar companion and its bundled engine. Accessibility authorization
is managed through macOS, never by editing its permission database.

**Launch at login** registers the companion with macOS. On startup, the companion
starts the engine through an on-demand LaunchAgent. The engine has no independent
login registration, so disabling the toggle prevents both from starting at login.
Disabling it leaves the current session running.

Build output stays in `.build/`. Signing selection lives outside the repository
at `~/Library/Application Support/local.paneru.preferences/development-signing.plist`.
Existing certificate-bound signing is retained when configured. No private keys
are stored in this repository.

See [the companion guide](PaneruPreferences/README.md) for controls and settings,
and [upstream provenance](PaneruEngine/UPSTREAM.md) for the engine changes.

## Validation

With the pinned Rust toolchain available on PATH:

```sh
cargo fmt --manifest-path PaneruEngine/Cargo.toml --check
CARGO_TARGET_DIR="$PWD/.build/paneru-engine" cargo clippy --manifest-path PaneruEngine/Cargo.toml --all-targets -- -D warnings
CARGO_TARGET_DIR="$PWD/.build/paneru-engine" cargo test --manifest-path PaneruEngine/Cargo.toml --all-targets
zsh PaneruEngine/build.sh
zsh PaneruPreferences/build.sh
```

The regression harness scrolls a real Bevy workspace, checks its offset through
hover, external/repeated focus and app activation, checks that a non-window click
does not release the hold, then confirms ordinary clicks preserve it and
Command-click reveals the window after mouse-up in either activation mode.
It uses a mock macOS window manager and does not move desktop windows.

Native checks on 2026-10-21 also covered starting the companion and bundled
engine from a stopped session, enabling/disabling/re-enabling macOS login
registration, and the compact popup with every shortcut visible. Registration
changes left the running engine untouched. Launch at login was left enabled;
the user's 0.35 speed, 4-point gap, and Mouse over mode were preserved. Login
registration was checked without logging the user out.

Overview revision 1.15 passed all 476 Rust tests, strict Clippy, formatting,
the Swift camera/hit-testing and reorder-queue checks, and a Swift build with
warnings treated as errors. Native checks on 2026-10-23 verified J to move left,
Control–Option–K to move right, stable selection after a move, and cursor-based
entry while keyboard selection and the original native focus pointed to two
other windows. The accept command exercised the same companion path requested
by a downward swipe; a physical trackpad gesture was not synthesized. Test window
order and focus were restored. Installed 1.15 (16) matches the signed build, and
saved preferences are unchanged.

Overview revision 1.16 passed 478 Rust tests, strict Clippy, formatting, Swift
selection/camera checks, a warnings-as-errors companion build, and an offscreen
render. Native checks used only the disposable `OverviewActionsFixture` app:
the Close button, Command–W, and context menu each closed exactly one requested
window while overview stayed open. Command–Q and the Quit button terminated that
app, including all four windows in the latter check. A simulated save sheet
exposed a modal-focus acknowledgment edge case; the close/quit recovery now
uncovers the app with a bounded fallback, and Cancel kept the test window open.
The fixture was quit, user window order/focus restored, and preferences preserved.
Installed 1.16 (17) matches the signed build.

## Local hardening and efficiency

Engine logs use `~/Library/Logs/Paneru` (directory `0700`, files `0600`).
Both launch paths refuse symlinks, hard links and non-regular log files, and
retain existing output. Legacy generated `/tmp` paths migrate on the next
engine start; the currently running installation is not modified by a build.
Generated window-rule comments flatten control characters from app metadata.

IPC keeps its existing Mach service and MessagePack protocol. Requests use
backpressure at 64 pending operations, subscriptions are limited to 64 live
clients, and layout batches are limited to 4096 operations. The transport rejects
payloads above 4 MiB before copying them, releases their resources, and uses
nonblocking one-shot replies. Native input producers are independent of IPC
admission. See `PaneruEngine/vendor/async-mach-ports/LOCAL_CHANGES.md` for the
small local transport patch and upstream provenance.

Native-tab recovery checks ECS geometry before native queries. Configuration
getters avoid whole-options copies. The companion retains framework symbols
and caches display mappings until screen changes, while live Space policy is
still read at input time. Subprocess workers grow on demand to the same maximum
concurrency as before and retire after 30 seconds idle.

Additional isolated checks (no desktop/window manipulation):

```sh
cargo test --locked --manifest-path PaneruEngine/vendor/async-mach-ports/Cargo.toml --all-targets
xcrun swiftc PaneruPreferences/Sources/DesktopSpaceSession.swift PaneruPreferences/Sources/Preferences.swift PaneruPreferences/Sources/ScrollPresets.swift PaneruPreferences/Sources/PrivateLogs.swift PaneruPreferences/Tests/main.swift -o .build/desktop-policy-tests
.build/desktop-policy-tests
```

## Retired prototype

The original RibbonDesk implementation, its fixtures, documentation and release
outputs have been removed from the active project. Git history preserves the
last version under the `ribbondesk-prototype-retired` tag. The repository URL and
local directory name remain unchanged so existing links continue to work.

Paneru is MIT licensed; see [third-party notices](THIRD_PARTY_NOTICES.txt).
