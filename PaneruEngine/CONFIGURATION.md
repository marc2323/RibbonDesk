# Configuration Guide

Paneru is configured via a TOML file *or* a Lua script — never both. By
default, it looks for the TOML configuration in the following locations (in
order):

1.  `$PANERU_CONFIG` (environment variable)
2.  `$HOME/.paneru`
3.  `$HOME/.paneru.toml`
4.  `$XDG_CONFIG_HOME/paneru/paneru.toml`

The configuration is automatically reloaded when the file is saved.

If an `init.lua` exists (see [Lua Scripting Guide](./SCRIPTING.md)), it takes over
completely and none of these TOML paths are read.

---

## 1. Global Options (`[options]`)

General behavior settings for the window manager.

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `focus_follows_mouse` | Boolean | `true` | If enabled, the window under the mouse cursor will automatically gain focus. |
| `preserve_scroll_until_click` | Boolean | `false` | Keep a manually scrolled viewport through hover, external focus changes, and ordinary clicks. Command-click reveals a managed window on mouse-up with a quick animation. A quick stationary three-finger tap focuses and reveals the managed window under the pointer; physical three-finger clicks also reveal on mouse-up. Three-finger taps are enabled by this option or a configured three-finger swipe, and leave Overview's input unchanged. Explicit keyboard focus navigation and window swaps reveal their target, taking over from scrolling. Enabled by the native companion's configuration. |
| `default_floating` | Boolean | `false` | New windows without an explicit `floating` rule start floating. RibbonDesk enables this; saved startup sessions retain their layout. App rules can use `floating = false` to add an app's new windows automatically. |
| `disabled_spaces` | Array (native Space IDs) | `[]` | Exclude these native macOS desktop Spaces from window discovery and pass global input through while one is active. The companion stores Space identities and resolves these IDs before starting the engine. |
| `mouse_follows_focus` | Boolean | `true` | If enabled, the mouse cursor will warp to the center of the focused window when focus changes via keyboard. |
| `horizontal_mouse_warp` | Integer ``(-1, 1)`` | Off | If enabled, the mouse will warp to another screen above or below, when touching the left or right edge. The direction depends on the direction - a negative value will cause the left edge to warp to a screen above and the right edge to a screen below. This allows having horizontal positioning of displays while having them aligned in a virtual layout in macOS settings. The cursor lands at the *opposite* edge of the target display (preserving cursor flow), with the source's relative Y position. Carries pre-warp horizontal velocity to avoid a "standing start", and skips the warp when the equivalent Y has no position on the target — matching macOS's native side-by-side behavior for displays of unequal height. (inspired by https://github.com/mogenson/WarpMouse.spoon) |
| `horizontal_mouse_warp_offset` | Integer (px) | `0` | Vertical pixel offset applied to the `horizontal_mouse_warp` landing position, signed by warp direction. Positive values shift the cursor lower when warping to a display *below* (in macOS arrangement) and higher when warping to one *above*. Use to compensate for physical desk arrangement differing from the macOS arrangement (e.g. portrait monitor sitting physically higher or lower than the laptop). |
| `preset_column_widths` | Array (Float) | `[0.25, 0.33, 0.5, 0.66, 0.75, 1.0, 1.5, 2.0]` | Ratios of the screen width used by the `window_resize` command and the menu bar width picker. Values above `1.0` create a horizontally scrollable oversized window. |
| `preset_stack_heights` | Array (Float) | `[0.25, 0.33, 0.5, 0.66, 0.75]` | Ratios of the viewport height used by the `window_vertical_resize` command. Only applies to windows inside a stack; every window in the column is kept at least 200px tall, so a ratio that would starve a neighbour is clamped. |
| `animation_speed` | Float | *None* | Speed of window animations. Comfortable range is from 8 to 20. Unset or set to a very high value to effectively disable animations. |
| `auto_center` | Boolean | `false` | Automatically center the focused window on the screen when switching focus. |
| `sliver_height` | Float (0.1–1.0) | `1.0` | Vertical ratio of off-screen windows kept visible to prevent macOS from relocating them. |
| `sliver_width` | Integer (px) | `5` | Horizontal width of off-screen windows kept visible. |
| `menubar_height` | Integer (px) | *Auto* | Manually override the detected macOS menubar height. |
| `window_hidden_ratio` | Float (0.0–1.0) | `0.0` | How much of a window can be hidden before it's forced into view on focus change. `0.0` = eager, `1.0` = lazy. |
| `window_resize_cycle` | Boolean | `true` | If disabled, `window_resize` and `window_shrink` (and their `window_vertical_*` counterparts) stop at the largest/smallest preset instead of cycling back. |
| `mouse_resize_modifier` | String | *None* | If enabled allows window resizing using mouse movement. For example `cmd + shift` will allow resizing of the window when holding those keys. Proximity of the pointer to left or right window edge determines which side will be adjusted. |
| `reap_empty_workspaces` | String | `false` | If enabled, a virtual workspace without any windows will be removed. |
| `disable_native_tabs` | Boolean | `false` | If enabled, Paneru will not auto-merge a window into a tab group with an existing same-app sibling that shares its frame. Merging happens when the window is created, and again for a background tab that the window server stops showing while a sibling of the same app holds the same frame — an app that hides its old tab a moment late would otherwise leave a column nothing can appear in. Use this if you find unrelated windows being grouped together. |
| `virtual_workspace_animations` | Boolean | `false` | If enabled, Paneru will animate virtual workspace swaps. Off by default, because people use virtual workspaces due to the slow animation of the native macOS workspaces. |
| `insert_windows_mid_strip` | Boolean | `false` | When moving a window to another virtual workspace, insert it at the column matching its current on-screen position (keeping it where you see it and shifting the rest) instead of appending it to the end of the destination strip. |
| `create_virtual_workspace_automatically` | Boolean | `false` | Automatically creates a new virtual workspace when using `window_virtual_south `or Southward gesture controls. |

---

## 2. Padding (`[padding]`)

Sets the margins at the edges of the screen.

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `top` | Integer (px) | `0` | Padding at the top of the screen. |
| `bottom` | Integer (px) | `0` | Padding at the bottom of the screen. |
| `left` | Integer (px) | `0` | Padding at the left edge. |
| `right` | Integer (px) | `0` | Padding at the right edge. |

---

## 3. Swipe & Gestures (`[swipe]`)

Configure trackpad gestures and scroll-wheel window sliding.

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `sensitivity` | Float (0.1–2.0) | `0.35` | Multiplier for swipe distance. |
| `deceleration` | Float (1.0–100.0) | `4.0` | Rate at which inertia slows down after a swipe. |
| `momentum` | Float (0.0–3.0) | `1.0` | Coast duration multiplier. Zero stops at release and disables flick snapping. |
| `snap_speed` | Float (0.0–3.0) | `0.0` | Minimum release speed in viewport widths per second to trigger a forward snap. Zero disables flick snapping. |
| `snap_visible` | Float (0.25–0.95) | `0.55` | Fraction of the destination column that the projected resting position must reveal before snapping. |
| `magnetic_snapping` | Boolean | `false` | Experimental local edge capture. Replaces flick snapping, auto-centering and the one-page gesture limit while enabled. |
| `magnet_strength` | Float (0.2–6.0) | `1.8` | Maximum speed a magnet catches at its center, in viewport widths/second. |
| `magnet_range` | Float (0.03–0.4) | `0.2` | Capture radius as a fraction of viewport width. |
| `three_finger_paging` | Boolean | `false` | Every horizontal three-finger gesture advances one window alignment, including nonstandard widths. Enabled by the settings companion. |
| `infinite_ribbon` | Boolean | `false` | Join both ends for horizontal scrolling and paging without changing column order. Overrides horizontal edge clamps for ribbons with at least two columns. |
| `snap_animation` | Float (0.2–4.0) | `1.0` | Snap spring speed multiplier; higher settles faster, independently of the flick threshold. |
| `snap_full_width` | Boolean | `true` | Snap columns within 90–102% of the viewport width to the leading edge. |
| `snap_half_width` | Boolean | `false` | Snap columns within 45–55% of viewport width to either edge. Enabled by the settings companion. |
| `snap_back` | Boolean | `false` | Permit snapping behind current swipe progress, including returning to the starting alignment. |
| `snap_exit_distance` | Float (0.0–0.5) | `0.12` | With snap_back enabled, projected distance needed to escape the starting alignment, as a fraction of viewport width. Zero removes its return zone. |
| `continuous` | Boolean | `true` | If `true`, the windows are allowed to fully move across the desktop, potentially exposing the empty desktop space. If `false`, the window strip will not move further than the left or right most window. This also affects the windows during keyboard focus - if `false` the left or right most windows will snap to the edge of display. |

Dragging follows physical input directly. On release, velocity drives an exponential
coast. A new touch stops it; pausing for 100 ms before lifting cancels the release
velocity. Modifier scrolling uses the same adjustable coast and consumes the native
macOS momentum tail to avoid applying inertia twice. Discrete wheels use a short
input timeout to detect release.

With `magnetic_snapping` enabled, both edges of every column act as local magnets
at the corresponding viewport edges. Finger-down movement remains direct. After
release, capture occurs inside `magnet_range` when velocity squared is below
`magnet_strength² × (1 − (distance/range)²)`. Fast motion passes through; ordinary
inertia continues until another edge can catch it. Capture uses the existing
critically damped `snap_animation` spring and can return to a nearby edge.
Momentum zero still permits a local catch. A short inaccurate drag outside every
capture zone stays between edges. The swept frame segment is checked to avoid
stepping over a narrow magnet, and integration remains capped after stalls.

This mode takes precedence over `three_finger_paging`, `snap_speed`, `snap_visible`,
`snap_full_width`, `snap_half_width`, `snap_back`, `snap_exit_distance`, and
`auto_center`; their saved values are preserved. Sensitivity, momentum, decay,
gesture direction, bounds and infinite-ribbon geometry still apply. No extra timer,
platform query or allocation is added to snap selection, and the scroll component
is removed at rest. Overview retains its separate panning behavior.

With `three_finger_paging` enabled and magnetic mode off, every nonzero horizontal three-finger gesture
commits exactly one adjacent alignment on lift, including slow gestures and pauses.
Dragging is bounded to that one step; net travel sets the direction after reversals.
Paging recognizes every column width, including apps with fixed or minimum sizes.
Columns narrower or wider than the viewport can align to either edge. It ignores
the free-scroll snap toggles and bypasses sensitivity, momentum, decay, speed/visibility thresholds,
and snap-back resistance. It retains `snap_animation`, gesture direction, layout
bounds, and interrupt-on-touch behavior. Other configured finger counts and modifier
scrolling keep their original behavior. No eligible destination leaves the viewport
where it began. Disabling paging restores the saved free-scroll settings.

With `infinite_ribbon` enabled, the first column follows the last in either
direction, including during coasting and snap animation. Columns retain their
logical order, widths, stacks, and tab groups. Each native window appears once;
short ribbons leave enough space for a column to leave the viewport before it
returns. A single column uses its normal bounds. Switching the option off stops
active scrolling and restores the ordinary bounds around the nearest visible
column. This option applies per ribbon and does not cycle between Desktops.
The companion uses the same option to loop Overview previews. In Overview,
two-finger scrolling uses AppKit input and three-finger horizontal gestures pan
the preview camera through the existing engine notification channel. Both use
free panning regardless of `three_finger_paging`; native ribbon windows stay
still. Vertical three-finger gestures retain their open/enter behavior.
Three-finger contact boundaries preserve the final movement packet before
release or cancellation. The companion supplies Overview-only inertial coasting;
the native ribbon's momentum and snap settings are independent.

Flick snapping is opt-in and independent of `auto_center` and scroll-position holds.
For a forward snap, release speed and projected visibility must both pass their
thresholds. Visibility scales with the destination column's width. By default,
the target must be ahead of both the gesture origin and current position, so
snapping never undoes progress. With `snap_back` enabled, candidates may be behind
the current position, and a gesture starting within 2px of an alignment may return
there if projected travel stays inside `snap_exit_distance`. Set either `momentum`
or `snap_speed` to zero to disable all snapping, including returns. A selected
column settles exactly at its chosen edge, accounting for Dock reservation and gaps.

### `[swipe.gesture]`

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `fingers_count` | Integer | *None* | Number of fingers for the swipe gesture. Set to 3 or more to enable. |
| `direction` | String | `"Natural"` | Direction of movement: `"Natural"` or `"Reversed"`. |
| `vertical` | Boolean | `true` | Interpret the vertical gestures with `fingers_count` or ignore them. Enabling this allows using vertical swipe gestures to change virtual desktops. |

When `fingers_count` is omitted or set below 3, Paneru does not intercept native macOS gestures. If macOS uses three-finger horizontal swipes for Spaces, prefer `[swipe.scroll]` with a modifier or configure a different finger count.

### `[swipe.scroll]`
| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `modifier` | String | `"alt"` | Modifier key(s) required to slide windows with the scroll wheel: `"alt"`, `"rcmd"`, `"ralt + cmd"`, `"lctrl + lalt + cmd"`, etc. |
| `window_step` | Boolean | `false` | Select one adjacent column per accepted wheel input. This uses the same focus commands as `window_focus_west` and `window_focus_east`. |
| `vertical_modifier` | String | *None* | Additional modifier key that, when held together with `modifier`, switches virtual workspaces vertically instead of scrolling horizontally. For example, if `modifier = "alt"` and `vertical_modifier = "shift"`, then `alt + scroll` slides windows horizontally and `alt + shift + scroll` switches virtual workspace rows. |

To select windows with Alt + mouse wheel, enable window steps:

```toml
[swipe.scroll]
modifier = "alt"
window_step = true
```

Window steps use the current focus commands and scroll direction.
Repeated inputs in the same direction are limited to one step every 180 milliseconds.
Momentum is ignored. Trackpad gestures and vertical workspace scrolling keep their existing behavior.

---

## 4. Decorations (`[decorations]`)

Visual styling for workspaces, active and inactive windows.

### Virtual Workspace indicators

Toggles display of the currently active virtual workspace in the menubar or in a brief status popup window. Both are enabled by default.
(Note: disabling menubar indicator requires a restart)

**Example:**
```toml
[decorations]
# Both default to true
workspace_menu_status = false
workspace_popup_status = true
```

### `[decorations.menu]`

Basic settings for the menubar display.

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `orientation` | String | `'default'` | Which of the menubar elements appears first, the descriptor `'default'` or the indicator `'flipped'`. |
| `colors` | [String] | `['#FFFFFF']` | An array of hex colors defining a linear gradient (left to right) coloring the menubar display. Set a solid color by including only one element. |
| `angle` | Float | `90.0` | The angle (in degrees) of the gradient. |

### `[decorations.menu.descriptor]`
Settings for the descriptor component of the menubar display. The descriptor component is a visual marker for the Paneru menubar item.
| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `style` | String | `'symbol'` | Composition of the descriptor. Options are any SF Symbol `'symbol'`, any string of text `'text'`, both of those `'both'`, or nothing `'hidden'` |
| `text` | String | `'VW'` | Text shown if `'text'` or `'both'` style is selected. |
| `symbol` | String | `'fish.fill'` | SF Symbol shown if `'symbol'` or `'both'` style is selected. SF Symbol names can be found in the [SF Symbols App](https://developer.apple.com/sf-symbols/), in the Xcode library, or in a variety of places online. |

### `[decorations.menu.indicator]`
Settings for the indicator component of the menubar display. The indicator component shows your current (and optionally all active) virtual workspace(s).

**Important Note: The `'unicode'` and `'marked'` formats only mean anything next to the workspaces they are not, so they are incompatible with the single-item `'mono'` and `'paged'` styles and will fall back to `'default'`.**

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `style` | String | `'mono'` | Whether the indicator displays all virtual workspaces `'multi'`, only your current workspace `'mono'`, or your current workspace over how many there are `'paged'` (`2 / 4`). |
| `format` | String | `'default'` | The format of the character(s) which represent your virtual workspace(s).<br>Options are regular numbers `'default'`, Roman numerals `'roman'`, any pair of Unicode characters `'unicode'`, or the inactive Unicode character with the active workspace shown as its number `'marked'` (`· 2 · ·`). |
| `font_size` | Float (2.0 to 24.0) | `13.0` | Font size of the indicator in point. |
| `active_character` | Char | `'☉'` | The Unicode character which represents an active workspace in the `'unicode'` format. |
| `inactive_character` | Char | `'○'` | The Unicode character which represents an inactive workspace in the `'unicode'` format. |


### `[decorations.inactive.dim] (Native macOS Dimming)`

Paneru supports native macOS window dimming. To use this mode, **only** set `opacity` (and optionally `opacity_night`). Do not set a `color`.

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `opacity` | Float (-1.0 to 1.0) | `0.0` | Dimming intensity. `-1.0` is fully black, `1.0` is fully white. |
| `opacity_night` | Float (-1.0 to 1.0) | *opacity* | Dimming intensity used when macOS is in Dark Mode. |

**Example:**
```toml
[decorations.inactive.dim]
opacity = -0.15
opacity_night = -0.25
```

---

## 5. Keybindings (`[bindings]`)

Bindings map a key combination to an action. A binding can be a single string or an array of strings.

Format: `"[modifiers-]key"`. For example `alt + cmd - j` and `cmd - j`.

Available modifiers are:
- `alt`, `lalt`, `ralt`
- `ctrl`, `lctrl`, `rctrl`
- `cmd`, `lcmd`, `rcmd`
- `shift`, `lshift`, `rshift`
- `fn`

For a full list of parseable keys (i.e. `leftarrow`) check the source:
https://github.com/karinushka/paneru/blob/3790b01f8d65df5d9000142db7cf25f9270dcccc/src/config.rs#L1466-L1601


### Window commands

| Action | Description |
| :--- | :--- |
| `window_focus_west` / `_east` | Focus window to the left/right. |
| `window_focus_north` / `_south` | Focus window above/below. If no window exists, switches focus to the display in that direction. |
| `window_focus_first` / `_last` | Jump to the start/end of the strip. |
| `window_focus_managed` | Switch to a previously focused window on this workspace. |
| `window_focus_unmanaged` | Switch to a previously focused floating window on this workspace. |
| `window_swap_west` / `_east` | Swap current window with neighbor. |
| `window_swap_north` / `_south` | Swap current window above/below. If no window exists, moves the window to the display in that direction. |
| `window_swap_first` / `_last` | Move current window to start/end of strip. |
| `window_center` | Center the current window in the viewport. |
| `window_resize` | Cycle through preset widths (Grow). |
| `window_grow` | Alias for `window_resize`. |
| `window_shrink` | Cycle through preset widths (Shrink). |
| `window_vertical_resize` | Cycle a stacked window through preset heights (Grow). No-op outside a stack. |
| `window_vertical_grow` | Alias for `window_vertical_resize`. |
| `window_vertical_shrink` | Cycle a stacked window through preset heights (Shrink). |
| `window_fullwidth` | Toggle full-width mode. |
| `window_manage` | Toggle between tiled and floating state. |
| `window ribbon <window-id> <pid> add\|float` | Set one exact standard window's Ribbon membership. Requires its current owner PID and active native workspace; stale, hidden, minimized, and other-workspace targets are ignored. |
| `window_stack` | Stack the current window into the column on the left. |
| `window_unstack` | Pull a window out of a stack into its own column. |
| `window_tabbeddisplay` | Toggle the focused stack between a normal split display and a tabbed display (one window visible at a time, sharing the full column). Cycle tabs with `window_focus_north`/`window_focus_south`. |
| `window_equalize` | Make all windows in a stack equal height. |
| `window_balance` | Make all columns in the strip the same width as the focused window. |
| `window_nextdisplay` | Move focused window to the next monitor and follow it. |
| `window_nextdisplaysend` | Move focused window to the next monitor but stay on current. |
| `mouse_nextdisplay` | Warp mouse cursor to the next monitor. |
| `window_snap` | Snap an overflowing window into the viewport. |
| `window_raise_floating` | Make the floating windows layer visible on the current workspace. |
| `window_togglefloatlayer` | Selectively move the floating windows in front or behind of the workspace windows. |
| `window_copyrule` | Copy a window rule template for the focused window to the clipboard. |
| `quit` | Exit Paneru. |
| `restart` | Restart the Paneru service (`paneru restart`). |

**Example:**
```toml
[bindings]
window_focus_west = "cmd - h"
window_resize = ["alt - r", "ctrl - r"]
```

### Virtual workspaces (Experimental)

Paneru allows having virtual spaces inside of the native macOS workspace.
Logically it can be thought of several strips of windows (rows) stacked on top
of each other within the single workspace. Similar to how Niri implements the
movement between the vertical workspaces.

Shifting up or down goes to the previous or next strip of windows - wrapping
around at the start or the end.

Moving the last window out of the virtual row, will "collapse it".

Virtual workspaces can also be navigated using trackpad gestures. If `[swipe.gesture]` is configured, a vertical 3/4-finger swipe will switch between virtual workspace rows, while horizontal swipes continue to scroll the strip as usual. For mouse users, see the `vertical_modifier` option under `[swipe.scroll]`.

| Action | Description |
| :--- | :--- |
| `window_virtual_north` / `_south` / `_first` / `_last` | Switch to the previous/next or first/last virtual workspace (row of windows), unconditionally. `_east` or `_west` are aliases for `_north` and `_south`. |
| `window_virtualfocus_north` / `_south` | Like `window_virtual_north`/`_south`, but if the focused window is in a stack and has a neighbor above/below, focuses that neighbor instead of switching — the same within-column traversal as `window_focus_north`/`_south`. Only switches the virtual workspace once there's nothing left to focus that way. No `_east`/`_west`/`_first`/`_last` form (there's no "focus" reading to pair with those). |
| `window_virtualnum_<number>` | Switch directly to the numbered virtual workspace. |
| `window_virtualmove_north` / `_south` / `_first` / `_last` | Move currently focused window to the previous/next or first/last virtual workspace and follow it. `_east` or `_west` are aliases for `_north` and `_south`. |
| `window_virtualsend_north` / `_south` / `_first` / `_last` | Move currently focused window to the previous/next or first/last virtual workspace but stay on the current one. `_east` or `_west` are aliases for `_north` and `_south`. |
| `window_virtualmovenum_<number>` | Move currently focused window to the numbered virtual workspace and follow it. |
| `window_virtualsendnum_<number>` | Move currently focused window to the numbered virtual workspace but stay on the current one. |


**Example:**
```toml
[bindings]
window_virtual_north = "cmd + shift - k"
window_virtual_south = "cmd + shift - j"
window_virtualmove_north = "cmd + alt - k"
window_virtualmove_south = "cmd + alt - j"
window_virtualnum_1 = "cmd + alt - 1"
window_virtualnum_2 = "cmd + alt - 2"
window_virtualnum_3 = "cmd + alt - 3"
window_virtualmovenum_1 = "cmd + alt + ctrl - 1"
window_virtualmovenum_2 = "cmd + alt + ctrl - 2"
window_virtualmovenum_3 = "cmd + alt + ctrl - 3"
window_virtualsendnum_1 = "cmd + alt + shift - 1"
window_virtualsendnum_2 = "cmd + alt + shift - 2"
window_virtualsendnum_3 = "cmd + alt + shift - 3"
```

**Example command line:**
```shell
# Move to the previous virtual workspace.
$ paneru send-cmd window virtual north
# Move the current window to the next virtual workspace.
$ paneru send-cmd window virtualmove south
# Move directly to virtual workspace 3.
$ paneru send-cmd window virtualnum 3
# Move the current window to virtual workspace 3 and follow it.
$ paneru send-cmd window virtualmovenum 3
# Send the current window to virtual workspace 3 and stay here.
$ paneru send-cmd window virtualsendnum 3
```

See [QUERY_AND_SUBSCRIBE_FORMAT.md](QUERY_AND_SUBSCRIBE_FORMAT.md) for the
structured `paneru query` responses and `paneru subscribe` event stream.

---

## 6. Window Rules (`[windows]`)

Define specific behaviors for applications based on their Title or Bundle ID.

| Option | Type | Description |
| :--- | :--- | :--- |
| `title` | Regex | **(Required)** Regex pattern to match the window title. |
| `bundle_id` | String | Optional Bundle ID to match (e.g., `com.apple.Terminal`). |
| `floating` | Boolean | Force the window to be floating/unmanaged. |
| `manage` | Boolean | Force Paneru to manage this app/window even if macOS reports the app as unobservable or the window has a non-standard role/subrole. |
| `index` | Integer | Preferred position in the strip when spawned. |
| `dont_focus` | Boolean | Prevent the window from taking focus when spawned. |
| `width` | Positive Float or `"complement_focused"` | Initial width ratio for the window. Values above `1.0` create an oversized, horizontally scrollable window. `"complement_focused"` uses `1.0` minus the focused window's width ratio; if there is no focused window or it is at least 95% wide, the new window starts at full width. |
| `grid` | String | placement for floating windows: `"cols:rows:x:y:w:h"`. |
| `horizontal_padding` | Integer | Gaps to the left/right of this window. |
| `vertical_padding` | Integer | Gaps to the top/bottom of this window. |
| `bindings_passthrough`| Array (String)| Keys that should bypass Paneru and go directly to the app. |

For example, use `width = "complement_focused"` in a window rule to give each
new window the width remaining beside the currently focused window. A new
window opened from a full-width window also starts at full width. This width
is chosen during initial placement, before the `window_spawned` Lua hook runs.

**Example:**
```toml
[windows.terminal]
title = ".*"
bundle_id = "com.apple.Terminal"
horizontal_padding = 5
bindings_passthrough = ["ctrl-h", "ctrl-l"]
```

### Copying a window rule

Neither the bundle ID nor the exact window title is visible anywhere in the UI,
so the Paneru menu bar has a **Copy Window Rule** entry. You can also trigger it
via a keybinding (e.g., `window_copyrule = "ctrl + alt - c"`) or run it from the
command line (`paneru window copyrule`). It puts a rule for the currently focused
window on the clipboard, ready to paste:

```toml
[windows.ghostty]
bundle_id = "com.mitchellh.ghostty"
title = "^paneru — zsh$"
# title = ".*"   # all windows of this app
# app: Ghostty  role: AXWindow  subrole: AXStandardWindow
# floating = true
# manage = true
# width = 0.5
```

The two matchers are live; everything else is a comment for you to uncomment.
`title` is anchored and regex-escaped so it matches only this window — swap in
the commented `.*` to cover every window of the app instead. The `app`, `role`
and `subrole` line is there to tell one pasted rule from the next; none of those
are matchable. When an `init.lua` is in charge, the snippet is written as a Lua
table instead of TOML.

### Forcing management of LSUIElement or non-standard windows

Some applications (e.g., BetterTouchTool, ProtonVPN) are flagged as background apps
(`LSUIElement`) or expose windows with unusual accessibility roles such as `AXTable`
or `AXTextField`. Paneru normally ignores these processes and windows. Use `manage = true`
to opt in and forcibly manage the matching windows.

```toml
[windows.btt_main]
bundle_id = "com.hegenberg.BetterTouchTool"
title = "BetterTouchTool"
manage = true

[windows.btt_screenshot]
bundle_id = "com.hegenberg.BetterTouchTool"
title = "Screenshot.*"
floating = true
```

### Session Restore

Paneru saves its managed window layout and can restore it the next time it
starts. Restore is a startup-only phase: Paneru loads the saved session, applies
it after initial window discovery, keeps matching open for a short grace period,
then stops consulting the saved state until the next Paneru process start.

The saved session includes:

- native workspace ids
- virtual workspace rows and the selected row per native workspace
- layout structure: singles, stacks, tabs, and fullscreen strips
- display/screen association
- window identity for matching across restarts

Matched startup windows use the saved session before static `[windows]` rules.
That means saved layout, virtual workspace, display, and managed/floating state
win over configured `index`, `floating`, `width`, and `grid` rules during
restore. Unmatched startup windows, and all windows created after the restore
grace period ends, keep normal `[windows]` behavior.

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `enabled` | Boolean | `true` | Enables session restore on startup. |
| `startup_grace_ms` | Integer (ms) | `2000` | How long Paneru keeps restore matching active after startup. This gives apps a chance to create windows shortly after Paneru starts. |
| `missing_windows` | String | `"ignore"` | Behavior when a saved window is not present during restore. Currently only `"ignore"` is supported, which drops the missing window and compacts the restored layout. |

**Example:**
```toml
[restore]
enabled = true
startup_grace_ms = 2000
missing_windows = "ignore"
```

Restore matches windows first by stable startup identity:

- window id
- process id
- bundle id

If an application has restarted and those ids changed, Paneru can use a
conservative fallback match:

- bundle id
- non-empty window title
- window identifier
- accessibility role
- accessibility subrole

Fallback matching is only used when it is unambiguous. If multiple current
windows could match the same saved window, Paneru skips that saved window rather
than moving the wrong one.

If a saved app or window is missing, the default `"ignore"` policy simply drops
it from the restored layout. Empty stacks, tab groups, columns, and virtual rows
are removed. If the previously selected virtual row is removed because all of
its windows are missing, Paneru selects the nearest remaining restored row for
that native workspace. If no restored row remains, the normal startup workspace
selection is kept.

For screens, Paneru prefers the current macOS workspace-to-display mapping when
the workspace is already present on a display. Otherwise it restores to the
saved display id when that screen is still connected, then falls back to the
current active display, then the first available display by id. Paneru does not
create placeholder displays or off-screen state for disconnected monitors.

---

## 7. Experimental Features

> [!WARNING]
> These features rely on undocumented macOS window-server APIs and have known issues. For example, overlay windows (like YouTube Picture-in-Picture) may be partially shaded, and layer ordering can behave unexpectedly. Both features are **disabled by default**.
>
> Disabling **System Integrity Protection (SIP)** is **not required**, but without it Paneru has limited control over window layering, which is the root cause of most visual edge-cases. Enable these only if you are comfortable with occasional glitches.

### Inactive Window Overlay Dimming
Another dimming option that draws a translucent overlay on every inactive window to visually emphasize the focused one.

**Activation:** This mode is enabled by setting **both** `opacity` and `color` under `[decorations.inactive.dim]`. In this mode, `opacity` ranges from `0.0` to `1.0`.

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `opacity` | Float (0.0 to 1.0) | `0.0` | Opacity of the dim overlay. `0.0` is transparent, `1.0` is opaque. |
| `color` | String (Hex) | `"#000000"` | Hex color for the dim overlay (default: black). |

**Example:**
```toml
[decorations.inactive.dim]
opacity = 0.3
color = "#000000"
```

### Active Window Border
Draws a colored border around the currently focused window.

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `enabled` | Boolean | `false` | Enable the active window border. |
| `color` | String (Hex) | `"#FFFFFF"` | Hex color for the active window border. |
| `opacity` | Float (0.0–1.0) | `1.0` | Opacity of the active window border. |
| `width` | Float (px) | `2.0` | Width of the border in pixels. |
| `radius` | Number/String | `"auto"` | Corner radius in pixels or `"auto"` to match system. |

**Example:**
```toml
[decorations.active.border]
enabled = true
color = "#89b4fa"
width = 2.0
radius = 12.0
```

> **Tip:** You can override the `border_radius` for specific applications in the `[windows]` section. See [Window Rules](#6-window-rules).

## 8. Lua Scripting

Paneru embeds a Lua runtime that allows full configuration via `init.lua`, replacing `paneru.toml` entirely. When a Lua configuration or script exists (`$PANERU_LUA`, `$HOME/.paneru.lua`, or `$XDG_CONFIG_HOME/paneru/init.lua`), it takes over completely and no TOML config is read.

All options, padding, gesture settings, window rules, and keybindings documented in sections 1–7 above are available under identical names via `paneru.setup{...}`.

In addition to static configuration, Lua scripting allows:
- **Event Hooks (`paneru.on`)**: React to window creation (`window_spawned`), focus changes, or space switches with optional filter specs or regex matchers.
- **Keybinding Callbacks (`paneru.bind`)**: Map hotkeys to custom Lua callbacks or commands.
- **State Queries (`paneru.query_*`)**: Read real-time window, workspace, and display layout state without round-trip shell executions.
- **Persistent State (`paneru.state`)**: Store and mutate data across reloads and daemon restarts.
- **Programmatic Layout Transformations (`ws`)**: Pure layout operations (`ws:focus`, `ws:swap`, `ws:float`, `ws:shift`, `ws:view`, etc.) for custom workflows like named scratchpads.

For complete documentation, event specifications, API reference, and examples, see the **[Lua Scripting Guide](./SCRIPTING.md)**.

### Companion ribbon overview

`[swipe] ribbon_overview = true` lets a physical upward three-finger gesture
request the native companion overview. It defaults to false for standalone
engine configurations. The companion enables it and binds Control–Option–O to
`overview show`. While the overview owns input, a downward three-finger gesture
requests `overview accept`, entering the companion's preview under the cursor.
The companion resolves the current pointer against its scrolled scene and uses
the same exact-window focus handoff as a click. Direction locking
emits one action per gesture; its Dock tail stays owned after the panel closes.
Excluded Spaces bypass the input tap as before.

The companion uses `send-cmd overview begin <companion-pid>` and `overview end`
to suspend/resume normal input, `overview focus <window-id>` to reveal an exact
managed window, and `overview move <window-id> <target-id> before|after` to insert
an entire column beside another. Missing IDs, different strips, and self-drops
are ignored. `overview dismiss` asks the companion to close while keeping input
suspended; Escape uses this cancel path. `overview accept` instead asks it to
choose the preview under the pointer while retaining ownership. `overview end`
is its final release and sends no echo notification.
`overview close <window-id>` presses the exact window's native close button;
`overview quit-app <window-id>` requests a normal quit of its owning process.
Both require active overview ownership and membership in the active strip.
They preserve native save/cancel behavior and rely on OS notifications to remove
windows. The companion offers selected-window buttons, a preview context menu,
and Command–W/Command–Q; it reveals the original window if a request leaves it
open so save dialogs are accessible.
During an active overview, focus snaps the strip/member geometry behind the
panel. A one-shot `local.paneru.overview.ready` notification names the selected
native ID only after the native app reports that ID focused, animations have
settled, and native geometry matches the committed position. The companion keeps
the panel until this acknowledgment and any optional animation complete, then
releases input. A missing owner
process is detected on the next input event so a crashed companion cannot keep
normal input suspended.

The overview also owns the separate session-level Dock-control stream for an
upward three-finger gesture. Raw type-29 touch packets alone do not cancel
Mission Control: type-30 Dock packets (subtype 23, axis 2) must be consumed through
finger lift and repeated end packets. Native pinch, horizontal, four-finger and
unowned vertical sequences remain passthrough. No global Mission Control
preference is changed. Packet field references:
https://github.com/noah-nuebling/mac-mouse-fix/blob/master/Helper/Core/Touch/TouchSimulator.m

Query records' optional `ribbon_frame` uses unbounded logical ribbon coordinates,
with padding removed. This supports one uniform camera transform in the companion
and preserves gaps, nonstandard widths, and vertical stacks even when native
window positions have been parked at a screen edge.
