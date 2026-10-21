# Paneru Settings

A local native preferences companion for the installed Paneru 0.5.2 engine.
It provides one template menu-bar icon, a SwiftUI settings popover, saved scroll
speed, gap, and activation controls, and a Control–Option shortcut layout. RibbonDesk stays
closed. The Homebrew Paneru executable and its Accessibility authorization are
unchanged.

The installed app is `~/Applications/Paneru Settings.app`. The existing
`~/Applications/Paneru.app` launcher starts the engine and the preferences icon.
Click the two-pane icon to open the settings dropdown, or press Control–Option–S.
Click the icon again, click outside, or press Escape to dismiss it. The popover
stays attached to the icon and cannot be detached into a separate window.
Right-click the icon for pause, restart, and quit controls.
The shortcut reference is always expanded. The popover adapts to the screen's
available height and scrolls when its contents do not fit.

**Activate windows** offers two modes:

- **Mouse over:** Paneru activates windows when the pointer moves over them.
- **Click:** Paneru's hover focus is disabled. A local event tap consumes the
  first click on an inactive application window and activates it; the next click
  interacts with the window. The activation click's mouse-up and drag are also
  consumed. Ordinary scrolling over inactive windows is blocked until activation.
  Menus, the desktop, system UI, and this settings popover keep normal behavior.

Choose a mode and **Save**. Click mode needs Accessibility authorization for
**Paneru Settings** itself, in addition to the engine's existing authorization.
Use **Allow Click Mode…**, enable it in System Settings → Privacy & Security →
Accessibility, then return and save. Click mode is not saved if permission or
the event tap is unavailable. Switching to Mouse over removes the event tap.
The guard uses public Accessibility and Core Graphics APIs and runs locally.
The Homebrew Paneru executable remains unchanged.

Settings live in `~/.config/paneru/preferences.json` and `preferences.lua`.
`init.lua` reads the Lua values on load. Speed and focus changes reload the configuration;
gap changes briefly restart Paneru because 0.5.2 applies per-window padding only
when a window is admitted. The current desktop's columns are normalized after
the refresh. The popover stays visible while settings are being saved.
Existing preference files without a focus mode retain their speed and gap and
default to Mouse over. Unsaved choices survive dismissing the popover so a mode
selection is retained while granting Accessibility.

| Control–Option + | Action |
| --- | --- |
| H / L, or left / right | Previous / next window |
| J / K | Move window left / right |
| 2 / 0 | Half / full usable width |
| R | Toggle half / full |
| F | Full usable width |
| T | Toggle floating |
| Home / End | First / last window |
| S | Settings |
| Q | Pause window management |

Build with `zsh PaneruPreferences/build.sh` from the RibbonDesk directory. It uses
the installed Swift compiler and native frameworks, and the configured local
signing certificate when available. Output is in `.build/paneru-preferences/`.
The source configuration is `paneru-init.lua`; the active copy is in the user's
Paneru config directory. Previous config and launcher files are retained under
`~/.config/paneru/backups/settings-panel-*`.

Native validation on 2026-10-21 covered both sliders, saving speed and gap,
returning focus to the settings controls after layout refresh, and preservation of
the final 0.20 speed and 6-point gap. Two visible half-width columns retained
928-point slots; WindowServer reported 922-point windows separated by 6 points.
All 15 registered chords have only Control and Option modifiers. Remote
synthetic key events do not exercise Paneru's physical modifier decoding.

The popover update was built, signed, and installed on 2026-10-21. Native
accessibility inspection identified the UI as a popover with both sliders and
the Save control. Saving speed at 0.25 and then restoring 0.20 succeeded inside
the popover; its native Cancel action dismissed it. The gap stayed at 6 points
and the Paneru engine kept running throughout the update.

The activation update preserved the user's newer 0.35 speed and 4-point gap.
Legacy JSON migration, both focus-mode serialization round trips, and value
bounds passed. Both modes saved successfully and wrote the expected Lua hover
flag. After the user granted Accessibility, a temporary button-counter app was
used with input diagnostics: the activation-required mouse-down was consumed,
and the subsequent click incremented the button once. The automation tool sends
an activation click before its target click. Test windows were closed, their
temporary floating rule was removed, and diagnostics were disabled. Click mode was
left active. The shortcut list has no disclosure control and remains expanded.
