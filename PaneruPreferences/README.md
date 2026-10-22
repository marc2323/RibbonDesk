# Paneru Settings

A native SwiftUI/AppKit menu-bar app for the bundled Paneru engine. Click the
three-window icon, or press Control–Option–S, to open its compact dropdown.
Click outside or the icon again to dismiss it. Right-click the icon for pause,
restart, and quit controls.

## Settings

- **Mouse over:** hovering activates windows. It never releases a scroll-position hold.
- **Click:** the first click activates an inactive application window; a subsequent
  click interacts with it. Background app scrolling is blocked until activation.
  This mode needs Accessibility authorization for Paneru Settings.
- **Launch at login:** starts the companion and bundled engine at login using
  macOS Service Management. Choose Save after changing it. If macOS requires
  approval, use the displayed Login Items button.
- **Scroll speed:** 0.20–1.50, in 0.05 steps.
- **Window gap:** 0–24 points, in 2-point steps. A gap change briefly refreshes the layout.

Save applies settings; Reset Defaults selects the default values for review.
The full shortcut reference is always visible and has no scrolling area.

## Shortcuts

Hold **Control + Option**:

| Key | Action |
| --- | --- |
| H / L or left / right arrow | Previous / next window |
| J / K | Move window left / right |
| 2 | Half width |
| 0 / F | Full width |
| R | Toggle half / full width |
| T | Toggle floating |
| Home / End | First / last window |
| S | Open settings |
| Q | Pause window management |

Focus commands preserve a held viewport until a window click. Three-finger
horizontal gestures scroll the strip; ordinary two-finger gestures scroll apps.

## Runtime and build

The installed bundle is `~/Applications/Paneru Settings.app`. Its helper engine
is `Contents/MacOS/paneru`; the original Homebrew executable is retained as a
fallback. The companion starts the helper through the
`com.github.karinushka.paneru` on-demand LaunchAgent. There is one engine instance.
Login launches stay quiet in the menu bar.

Settings live in `~/.config/paneru/preferences.json` and `preferences.lua`.
`paneru-init.lua` is the source of the installed `init.lua`. Speed and focus
changes reload configuration; changing only login registration does not disturb
the engine. Width calibration runs for new windows and explicit gap refreshes,
never during ordinary hover or activation. Existing preference files migrate
without resetting their speed, gap, or focus mode.

Build the engine with `zsh PaneruEngine/build.sh`, then the companion with
`zsh PaneruPreferences/build.sh`, or run `zsh PaneruPreferences/install.sh` for both.
Builds use the configured local signing identity without changing certificate
trust. Signing scripts and public identity selection now belong to this app;
no original RibbonDesk runtime is needed.
