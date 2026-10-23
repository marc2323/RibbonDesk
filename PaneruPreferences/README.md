# Paneru Settings

A native SwiftUI/AppKit menu-bar app for the bundled Paneru engine. Click the
three-window icon, or press Control–Option–S, to open its compact dropdown.
Click outside or the icon again to dismiss it. Pause/Start, Restart, and Quit are
in Settings under Window management. Right-click the icon to show only Quit.

## Settings

- **Mouse over:** hovering activates windows. It never releases a scroll-position hold.
- **Click:** the first click activates an inactive application window; a subsequent
  click interacts with it. Background app scrolling is blocked until activation.
  This mode needs Accessibility authorization for Paneru Settings.
- **Launch at login:** starts the companion and bundled engine at login using
  macOS Service Management. Changes apply automatically. If macOS requires
  approval, use the displayed Login Items button.
- **Three-finger paging:** enabled by default. Every horizontal three-finger swipe
  advances exactly one window alignment, regardless of speed or distance.
  Apps with fixed or minimum widths are included, with either edge available for
  windows narrower or wider than the screen.
  It follows your fingers within that one step, then finishes at lift even after
  a pause. Reversing before lift uses the gesture's net direction. Touching again
  interrupts the animation. Paging stops at the first/last alignment.
  Paging overrides speed, momentum, decay, flick/visibility thresholds, snap-back
  resistance and full/half toggles for three-finger gestures. Snap animation still
  controls the transition. Modifier scrolling keeps all of its existing tuning.
  Turn paging off to restore free scrolling. The mode applies live and is included
  in new feel presets; existing presets restore their original free-scroll behavior.
- **Scroll speed:** 0.20–1.50. Drag to fine-tune the distance moved under your fingers.
- **Momentum:** 0–3×. Higher values coast farther after a flick.
  Zero stops at release and disables flick snapping. Default: 1×.
- **Momentum decay:** 1–100 (default 4). Higher values make the coast fade sooner,
  without changing the initial flick speed or your Momentum setting. Changes apply live.
- **Flick threshold:** minimum release speed, in screens per second (default 0.8/s).
  Higher values require a faster flick; zero turns flick snapping off.
- **Snap visibility:** how much of a destination window the projected coast must
  reveal (25–95%, default 55%). Higher values require more travel before snapping.
  Both snap thresholds must pass for a forward snap. Slow releases coast freely.
- **Full-width / Half-width windows:** independent snap toggles. Half-width columns
  can align to either edge; both sizes are enabled by default in the companion.
- **Snap animation:** 0.2–4× (default 1×). Higher settles faster, independently of
  Flick threshold. Touch again to cancel a coast or snap.
- **Snap back:** off by default, so snapping cannot undo swipe progress. Enable to
  allow small swipes to return to their starting alignment. **Exit distance** sets
  the projected travel needed to escape (0–50% of the screen, default 12%).
  Zero removes the return zone. Momentum or Flick threshold at zero disables all snapping.
- **Feel presets:** enter a name and choose Save Current to store all scrolling and
  snapping values. Choose a saved preset and Load to apply it immediately. Reusing
  a name updates it; the trash button deletes it. Presets persist in
  `~/.config/paneru/scroll-presets.json`, independently of Desktop, login, and appearance.
  The shortcut reference stays visible alongside the controls.
- **This Desktop:** saves whether Paneru runs on the current native
  macOS desktop Space. Turn it off to use normal macOS windows there.
  Tiling, strip gestures, hover activation, click protection, and all Paneru
  hotkeys are inactive. Return to an enabled desktop to resume automatically;
  a manual global pause stays paused. Use the menu-bar icon to re-enable an
  excluded desktop, since its settings hotkey is also inactive.
- **Window gap:** 0–24 points, in 2-point steps. A gap change briefly refreshes the layout.
- **Active window outline:** a 2-point teal outline highlights the focused window.
  Use the color well or hex field to choose any color, or turn the outline off.
  Complete six-digit colors apply automatically; partial hex input waits until valid. Color and outline changes reload without restarting the engine.

Each slider shows a short explanation underneath, including what its minimum and
maximum values do. The shortcut reference stays visible alongside the controls.

All settings apply and persist automatically. Sliders and the color picker update
while you adjust them, with rapid edits coalesced about every 80 ms. Controls stay
editable during an update; newer edits apply in order after the current update
finishes. Closing the dropdown does not discard pending changes. Failed changes
restore the last applied values and show the error. Reset Defaults applies immediately.
Gap changes still briefly refresh the layout.

The widget uses matching General, Scrolling, Appearance, and Shortcuts sections,
with aligned labels, smooth slider tracks, and consistent control sizes. The full
shortcut reference stays visible without scrolling in both light and dark mode.

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
| J / K | Move window left / right and follow it into view |
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
**J/K follows the moved window** into its new position and stops any active coast.
Another trackpad scroll restores the hold; hover and activation keep it in place.

## Runtime and build

The installed bundle is `~/Applications/Paneru Settings.app`. Its helper engine
is `Contents/MacOS/paneru`; the original Homebrew executable is retained as a
fallback. The companion starts the helper through the
`com.github.karinushka.paneru` on-demand LaunchAgent. There is one engine instance.
Login launches stay quiet in the menu bar.

Settings live in `~/.config/paneru/preferences.json` and `preferences.lua`.
`paneru-init.lua` is the source of the installed `init.lua`. Scrolling, focus,
and outline changes reload configuration; changing only login registration does not disturb
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
xcrun swiftc PaneruPreferences/Sources/DesktopSpaceSession.swift PaneruPreferences/Sources/Preferences.swift PaneruPreferences/Sources/ScrollPresets.swift PaneruPreferences/Sources/PrivateLogs.swift PaneruPreferences/Tests/main.swift -o .build/desktop-policy-tests
.build/desktop-policy-tests
```

The live-apply queue has independent checks with fake persistence (no desktop actions):

```sh
xcrun swiftc -swift-version 5 PaneruPreferences/Sources/Preferences.swift PaneruPreferences/Sources/PreferencesAutosaver.swift PaneruPreferences/Tests/Autosave/main.swift -o .build/preferences-autosave-tests
.build/preferences-autosave-tests
```

With Lua installed, validate the preference-to-engine configuration bridge:

```sh
lua PaneruPreferences/Tests/scroll-config.lua PaneruPreferences/paneru-init.lua
```

These checks also cover scrolling preference migration, persistence, validation,
outline preference migration, color validation, and Lua
output. Engine regressions cover outline geometry across display seams and
event-driven updates with no overlay work at idle. The outline ignores mouse
input and hides while windows scroll, move, or resize, including scroll inertia.
It returns after 150 ms without movement, using the focused window's final
position and current color. During continuous movement it hides once; native
outline checks and rendering wait until settling. The quiet period uses the
existing event loop without adding a polling timer. It also hides during
Mission Control, native fullscreen, or loss of a visible focused window.
Rendering reuses one compact, display-clipped overlay per touched display.

Engine logs are private files in `~/Library/Logs/Paneru`; unsafe links and file types are refused at startup. Builds do not restart the installed application.
