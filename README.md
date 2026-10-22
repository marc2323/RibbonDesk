# Paneru with native settings

A compact macOS menu-bar companion and a local build of Paneru 0.5.2. The dropdown
controls activation mode, scroll speed, window gaps, the active window outline,
and launch at login, with the
complete Control–Option shortcut list visible without scrolling.

- `PaneruPreferences/`: SwiftUI/AppKit companion, click protection, icons, and installer.
- `PaneruEngine/`: Paneru source with a per-workspace scroll-position hold and regression tests.

Scrolling keeps its natural inertia. Once placed, the viewport stays where the
user left it through hover, repeated focus notifications, and application
activation and ordinary clicks. **Command-click a managed window** to snap it
into view on mouse-up with a quick animation (about 150ms). **Previous/Next window
hotkeys always scroll to the selected window**, even after manual scrolling.
Hover and ordinary focus notifications keep the manually chosen viewport.

**Enable on this Desktop** in the menu-bar settings controls each native macOS
desktop Space separately. Disable it and Save to turn off Paneru's tiling,
gestures, activation, click protection, and hotkeys on that desktop. Switching
back to an enabled desktop resumes Paneru. Re-enable an excluded desktop through
the menu-bar icon; its settings hotkey is also inactive.

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

## Retired prototype

The original RibbonDesk implementation, its fixtures, documentation and release
outputs have been removed from the active project. Git history preserves the
last version under the `ribbondesk-prototype-retired` tag. The repository URL and
local directory name remain unchanged so existing links continue to work.

Paneru is MIT licensed; see [third-party notices](THIRD_PARTY_NOTICES.txt).
