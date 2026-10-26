# Settings guide

RibbonDesk’s native menu-bar app controls the bundled Paneru window engine.
For downloads and installation, see the [main README](../README.md#install).

Open Settings by clicking the three-window menu-bar icon or pressing
**Control–Option–S**. Click outside or click the icon again to dismiss it.
Right-clicking the icon shows App Behavior and Quit.

Settings apply and save automatically, including sliders while you drag them.
You can keep editing while an update finishes. The footer reports progress or
errors; a failed update restores the last applied values. **Reset Defaults**
restores the default preferences.

## General

| Setting | What it does |
| --- | --- |
| **This Desktop** | Enable or disable window management on the current macOS Desktop. |
| **Launch at login** | Start the companion and bundled engine when you log in. |
| **Activate on: Mouse over** | Activate windows when you hover over them. |
| **Activate on: Click** | First click activates an inactive window; click again to interact. Requires Accessibility access for RibbonDesk. |

### Per-Desktop management

Turning off **This Desktop** disables tiling, gestures, hover activation, click
protection, and RibbonDesk shortcuts on that native macOS Space. Return to an enabled
Desktop to resume. A manual global pause stays paused.

Use the menu-bar icon to re-enable an excluded Desktop, since its Settings
shortcut is also disabled there. Exclusions follow stable Space identities, so
reordering Desktops does not change their settings. With multiple displays, the
active menu-bar display determines whether the engine runs.

### Launch at login

If macOS requires approval, use **Approve in Login Items…** in Settings. Disabling
launch at login leaves the current session running. The companion manages login
registration for both components; the engine has no separate login registration.

## Window management

New windows start floating at their normal size and position. Focus a window
and press **Control–Option–T** to add it to the Ribbon; press it again to float
it. Existing saved sessions restore their arrangement.

Open **App Behavior…** from Settings or the icon's right-click menu to choose
how each app's future windows open:

| App choice | Behavior |
| --- | --- |
| **Use global default** | Float, with a prompt if global prompts are enabled. |
| **Automatically join Ribbon** | New windows join automatically. |
| **Always start floating** | New windows float without a prompt. The hotkey can still add one. |
| **Ask each time** | New windows float while a small prompt offers Add to Ribbon or Keep Floating. |

Prompts are off by default. **Remember for this app** in a prompt saves that
choice for future windows; ordinary hotkey toggles affect only the current
window. Rules use stable app bundle identifiers. Apps appear as their windows
are discovered, and **Add App…** lets you select an app that isn't running.
Search matches names and bundle identifiers. App choices apply on enabled
Desktops; standard dialogs and RibbonDesk's own controls keep normal behavior.

The local activity log retains the latest 200 window decisions and preference
changes. **Clear Log** clears history while retaining app choices;
**Reset App Preferences** returns apps to floating with prompts off. App Behavior
has its own reset, separate from the main Settings reset. Its catalog and engine
export are stored in `~/.config/paneru/app-behavior.json` and `app-behavior.lua`.

| Control | What it does |
| --- | --- |
| **Pause / Start** | Stop or resume window management. |
| **Restart** | Restart the bundled engine. |
| **Overview** | Open Ribbon Overview. |
| **Quit** | Stop the engine and close the companion. |
| **Overview animation** | Off switches instantly; on restores the 160 ms zoom. Reduce Motion disables the zoom. |

Overview controls are listed in the [main README](../README.md#ribbon-overview).
The view uses one-third scale; unusually short displays can impose a smaller
scale to fit the ribbon’s height. Browse with two- or three-finger horizontal
scrolling, the mouse wheel, or the bottom track. Both finger counts use free
panning in Overview, independently of the normal ribbon's three-finger paging.
With **Infinite ribbon** on, previews continue from the last window to the first
in either direction. The same toggle controls both views.

Three-finger panning follows your fingers and coasts smoothly when released;
a new touch, wheel input, navigation, or exit stops the coast. Pausing before
lifting deliberately stops it. Two-finger scrolling keeps macOS momentum.
Overview opens with the starting window centered, including the first and last
windows in a bounded ribbon. A small light-blue arrow points down at its top
middle edge throughout the session, independently of hover selection. Only one
visible copy is marked on a repeating ribbon. Closing that window removes its marker.

When rearranging, repeated J/K steps keep the selected window visible. Dragging
onto the left/right half of a preview inserts before/after it; holding a drag
near a screen edge scrolls the overview. Stacks and native tab groups stay together.

Closing or quitting from overview sends a normal native request. An app can ask
to save or cancel, and overview reveals its confirmation. Quit affects the app’s
other windows too.

## Scrolling

Turn on **Infinite ribbon** to join both ends: scrolling right past the last
window brings back the first, and scrolling left past the first brings back the
last. It works in Overview, with three-finger paging and Control–Option free scrolling,
preserves window order, and applies immediately. It is off by default and saves
separately from feel presets. A single column retains its normal scrolling;
short native ribbons leave room for a window to leave the screen before it returns.
Overview can repeat previews across a short ribbon while sharing their cached images.

**Three-finger paging** is enabled by default. Each horizontal three-finger swipe
advances exactly one window alignment, follows your fingers, and finishes when
you lift them. It includes fixed-width apps and can align either edge of a window.
Speed, swipe distance, and the free-scrolling thresholds do not skip or prevent
that step. **Snap animation** controls how quickly it settles.

Turn paging off for free scrolling. Holding **Control–Option** while scrolling
also uses free-scrolling behavior, regardless of the paging toggle.

| Setting | Range | Effect |
| --- | --- | --- |
| **Scroll speed** | 0.20–1.50× | How far the ribbon moves while your fingers are down. |
| **Momentum** | 0–3× | How far it coasts after release. Zero stops immediately and disables free-scroll snapping. |
| **Momentum decay** | 1–100 | How quickly a coast fades. Higher values stop sooner without changing the initial flick speed. |

Touch again to stop a fling, or pause before lifting to stop in place. Ordinary
hover, focus notifications, and clicks keep a manually chosen viewport.
**Command-click** reveals a managed window with a short animation on mouse-up.
Navigation hotkeys reveal their target; J/K follows a moved window and stops
an active coast. Another manual scroll restores the viewport hold.

## Snapping

Free scrolling can finish by snapping a sufficiently fast flick to a window
alignment. The projected coast must satisfy both **Flick threshold** and
**Snap visibility**. These settings do not tune one-window three-finger paging.

| Setting | Range | Effect |
| --- | --- | --- |
| **Full-width / Half-width windows** | On / off | Choose which window sizes can trigger a snap. Half-width windows can align to either edge. |
| **Flick threshold** | 0–3 screens/second | Minimum speed for a forward snap. Lower values allow gentler flicks; zero disables free-scroll snapping. |
| **Snap visibility** | 25–95% | How much of the destination window the projected coast must reveal. Higher values require more travel. |
| **Snap animation** | 0.20–4× | How quickly a triggered snap settles. Higher is faster. Touch again to cancel. |
| **Snap back** | On / off | Allow a small swipe to return to its starting alignment. Off by default. |
| **Exit distance** | 0–50% of screen | With Snap back on, how far the predicted travel must go to escape the starting alignment. Zero removes the return zone. |

## Appearance

**Window gap** ranges from 0 to 24 points in two-point steps. Changes briefly
refresh the layout. The **active-window outline** is a two-point border around
the focused window. Toggle it off, choose a color with the color well, or enter
a complete six-digit hex color. Color and outline changes reload configuration
without restarting the engine.

## Feel presets

Enter a name and choose **Save Current** to store scrolling and snapping together,
including the paging toggle. Reuse a name to update it. Choose a saved preset and
**Load** to restore it, or use the trash button to delete it.

Presets exclude Desktop policy, login registration, activation, appearance,
infinite ribbon, and overview animation. Older presets retain their original free-scrolling mode.

## Permissions and troubleshooting

- **Click mode:** use **Allow Click Mode…**, grant Accessibility access in macOS,
  then select Click again.
- **Blank previews:** use **Allow Window Previews…** and allow Screen Recording
  for RibbonDesk. Protected content can remain blank. Previews are snapshots;
  app interaction resumes after entering a window.
- **Inactive gestures or shortcuts:** check that the engine is running and
  **This Desktop** is enabled.
- **Login approval:** use the Login Items button when Settings reports that
  approval is required.

For configuration files, logs, builds, and tests, see the
[development guide](../docs/DEVELOPMENT.md).
