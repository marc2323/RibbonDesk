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
- **Enable on this Desktop:** saves whether Paneru runs on the current native
  macOS desktop Space. Turn it off and Save to use normal macOS windows there.
  Tiling, strip gestures, hover activation, click protection, and all Paneru
  hotkeys are inactive. Return to an enabled desktop to resume automatically;
  a manual global pause stays paused. Use the menu-bar icon to re-enable an
  excluded desktop, since its settings hotkey is also inactive.
- **Window gap:** 0–24 points, in 2-point steps. A gap change briefly refreshes the layout.

Save applies settings; Reset Defaults selects the default values for review.
The full shortcut reference is always visible and has no scrolling area.

Desktop exclusions follow native Space identities rather than desktop numbers,
so reordering desktops retains their choices. The original desktop can have no
UUID; it uses its native root ID. With multiple displays, the active menu-bar
display determines whether the engine runs. Windows on excluded desktops remain
unmanaged while using an enabled desktop on another display. Removed desktops
do not cause newly created desktops to inherit their exclusion.

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

Three-finger horizontal gestures scroll the strip; ordinary two-finger gestures
scroll apps. Ordinary clicks keep a manually scrolled viewport in place, so you
can work in partially visible windows. **Command-click a window** to bring it into
view with a quick animation (about 150ms) after releasing the mouse button.
Either Command key works in Mouse over and Click modes. **Previous/Next and
First/Last hotkeys always reveal their target**, taking over from manual scrolling.
Another trackpad scroll restores the hold; hover and activation keep it in place.

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

The desktop lifecycle checks are independent of desktop windows:

```sh
xcrun swiftc PaneruPreferences/Sources/DesktopSpaceSession.swift PaneruPreferences/Tests/main.swift -o .build/desktop-policy-tests
.build/desktop-policy-tests
```
