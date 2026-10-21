# RibbonDesk

The current setup uses the installed [Paneru](https://github.com/karinushka/paneru)
engine with a native menu-bar settings companion in
[PaneruPreferences](PaneruPreferences/README.md). The companion provides a compact
popover for activation mode, scroll speed, window gaps, and the full shortcut
reference. Build it with `zsh PaneruPreferences/build.sh`.

The original RibbonDesk prototype is paused. Its source, tests, assets, scripts,
and validation records are retained here alongside the Paneru companion. Run
only one window-management engine at a time.

This repository tracks project files. Generated build caches, app bundles,
release outputs, local signing credentials, and machine preferences remain local.

## RibbonDesk prototype 0.11 (paused)

A native macOS scrolling window manager written in Swift, AppKit, and SwiftUI.
Current evidence is in [Docs/VALIDATION.md](Docs/VALIDATION.md); earlier validation
and release archives are retained.

## Use

Launch `dist/RibbonDesk.app` with Accessibility enabled for that exact bundle.
RibbonDesk saves original frames **before moving a window**, then places eligible
windows side by side on their existing desktops. Each desktop on each connected
display has its own strip, order, focus, and offset. Switching desktops selects
that desktop's strip and captures its originals before its first layout. Windows
are not gathered or transferred between Spaces.

Swipe horizontally **anywhere with three fingers**. Two-finger scrolling,
page navigation, and native wheel momentum keep their system route. Vertical
three-finger gestures and other finger counts stay available to macOS.
The display where a ribbon gesture starts owns the complete gesture.

Windows start at **half-screen width** and fill the display's **usable height**,
leaving the macOS menu bar and Dock available. Two half-width windows and their
8-point gap fit the usable screen exactly. Choose **Half** or **Full** for the
focused window; full width spans two half-screen positions. Native fullscreen
mode and desktop membership are unchanged.

The ribbon follows your fingers continuously, then settles onto a **half-screen
position**. A deliberate short flick advances to the next position even when
finger travel is less than half a slot; a slow drag chooses the nearest position.
The final contact sample counts, including brief swipes and staggered finger lifts.
Tiny contact noise, cancelled input, and reversals against net travel do not force
an advance. A new swipe interrupts the current settle from its displayed position.

After momentum and settling finish, RibbonDesk samples the pointer's current
position and activates the managed window beneath it, bringing that window on top.
The hit must agree with both the final ribbon layout and the app's actual window
frame. A pointer in a gap or outside a managed window falls back to the nearest
column. Focusing does not move the settled ribbon again. Keyboard focus changes
activate immediately and reveal the selected window on the same grid.
Use **Control + Option + H / L** to switch windows.

Expand **Motion controls** in the dashboard to tune:

| Setting | Range | Default | Effect |
| --- | --- | --- | --- |
| Speed | 0.5×–5× | 2× | Travel for the same finger movement |
| Sensitivity | 0.5×–2× | 1× | Higher values start a swipe with less movement |
| Acceleration | 0%–100% | 15% | Fast swipes travel farther; 0% gives linear motion |
| Momentum | Off–100% | 35% | Travel after lifting; Off starts settling immediately |

Settings save between launches and apply to live control and the isolated demo.
**Reset Defaults** restores all four values. This update retains existing saved
values. At normal refresh, the default 35% flick coasts for at most 350 ms before
settling; 25% allows 250 ms, and 100% allows one second. The cap in seconds equals
the momentum amount from zero to one. Scheduling stalls can extend elapsed time.
Momentum keeps the lift velocity continuous, with firmer decay, and tunes both
travel and duration. Release velocity supplies short-flick direction without
adding a second prediction after momentum. Staggered
finger lifts retain velocity; a fresh touch or movement of the
remaining fingers interrupts coasting. Reversals immediately replace the previous
velocity direction. If the raw touch stream omits an end event, a 70 ms quiet
interval starts release handling.

An app's minimum width can promote a half-width column to full width. Apps that
cap their height retain their supported shorter height. A window that cannot fit
a supported slot is restored to its original frame and left floating while the
other windows remain in the ribbon.

RibbonDesk's own dashboard is a column on the desktop where it is open. Its
column is revealed at launch so its inclusion is visible. The optional bottom
status/pause bar is not a column and is not needed for input. Hidden/minimized
apps, fullscreen windows, dialogs, fixed-size windows, excluded apps, and
ambiguous native tabs remain unchanged. System Settings is included by default. Other desktops are left alone until
visited. RibbonDesk stays only on its own desktop. Normal titled windows from the
isolated RibbonDesk Preview are eligible too; status panels are not columns.

Newly opened or reopened eligible windows join their current desktop automatically
on the next idle check (about one second). A cheap WindowServer identity check
triggers AX discovery only when the candidate set changes. Discovery waits for
swiping, coasting, snapping, and layout to finish. Originals append before the
first move; existing originals and relative column order remain intact. Closing
a managed window reconciles its desktop rather than pausing every strip.

For this gesture setup, use four fingers for macOS “Swipe between full-screen
apps,” two fingers for “Swipe between pages,” and disable Three Finger Drag.
RibbonDesk does not change system trackpad preferences.

## Restore and recovery

**Pause / Restore** removes live input and restores original frames across visited
desktops. Quit also attempts restoration. If a hidden/minimized/inaccessible
window cannot restore, its record stays pending. Make it available, visit its
desktop if needed, then choose **Restore Saved Arrangement**. New sessions never
overwrite pending recovery. Displays must match the saved topology. Closed
windows/processes retire; restarted apps never inherit another process's records.

Originals are stored privately (file 0600, folder 0700) at:

```text
~/Library/Application Support/local.prototype.RibbonDesk/original-arrangement.json
```

The file contains window/process identity, title, frame, display geometry, Space
IDs, capture time, and pending restoration IDs. It contains no screenshots or
application contents. Old 0.3–0.5 recovery files remain readable. Only restoring
an older snapshot that previously transferred windows can use the legacy Space
transfer path; sessions from 0.6 onward preserve desktop assignments.

Display configuration changes and sleep stop control with originals retained.
Mission Control is observed through Dock AX notifications; its temporary window
thumbnail transforms are not used to update or drive ribbon geometry. Desktop
switching preserves the current strip and resumes the destination strip.

## Motion

Touch classification and inertia use pure contact math. The OS event tap listens
only for AppKit gesture events, never scroll-wheel events. The display link is
pinned to the display owning the gesture. Only that display enters a swipe batch.

External applications now receive position requests concurrently through one
serial lane per process. Windows inside one app keep their travel order; another
app's slow AX call no longer postpones when their requests begin. RibbonDesk's
own window moves on main alongside the external lanes. One completion barrier
waits for all lanes, including local work.
Position requests use public Accessibility APIs; local movement uses AppKit.

The controller allows one frame in flight. Direct input and coast updates submit
the latest target on the next main-runloop turn; updates received while it is
busy coalesce into one follow-up after the barrier. Old frames are not replayed.
The common strip offset is rounded once before deriving every native frame.
Presentation state advances only after the whole batch completes.
A cancelled batch makes its target cache entries unknown until reconciled. Frame
cancellation, resizing, restoration, and final pointer focus wait for outstanding
native calls. Native calls themselves cannot be interrupted mid-request.

Gesture planning performs pure geometry without screen enumeration, CG inventory,
AX eligibility queries, or resize/convergence polling. Space, display, and
Mission Control changes invalidate motion; full native checks remain at session
and settled-layout boundaries. The dashboard miniature publishes completed
geometry at most 15 times per second, independently of native window writes.

Direct tracking has no second presentation filter. The display clock drives the
monotonic 120–200 ms snap; settling waits for an in-flight batch and starts from
its completed position. Reversals discard unpresented travel in the old direction.
Saved motion settings are unchanged.

For apps exposing the existing undocumented `AXEnhancedUserInterface` attribute,
an application lane borrows the move-animation setting once and holds it through
the motion session. All outstanding writes finish before drain, cancellation, or
error restores the original value. Transient capability reads remain retryable;
failed restoration remains owed for retry. Raising alone never borrows the flag.

Motion batches do not raise windows. Final layout still orders visible columns
above parked ones on a best-effort basis. Partly visible windows keep their ideal
strip position until fully outside, then retain a 5-point edge handle. Parking
at occupied display seams stays inside the owning display. There is no new private WindowServer motion or
transaction API; the existing private Space helper remains limited to desktop
identity and legacy recovery operations.

Parallel AX starts and a shared barrier reduce avoidable serial delay. Each app
still controls when it handles and presents a request. This is not an atomic
pixel transaction, and a slow provider can still delay the next coherent frame.
Overflow slivers can overlap while parked. The first native 0.11 trial remained
jittery. In build 13, the user reported “Smoother; focus correct” after slow drag,
flick, reversal and pointer-focus tests on their desktop. Request timing and this
scoped result do not establish atomic presentation or universal compatibility.

At drained settled-layout and restoration boundaries, a stale AX failure can
resolve the same window once and retry once. Refresh requires the saved process,
bundle, and exact native window number; it never selects by title or geometry.
Hidden, minimized, ambiguous, or ineligible windows keep their saved recovery
record. A refreshed proxy replaces the session's cached object for later motion.

Settled size changes destined for an offscreen slot resize at a safe origin on
the same display before parking. This avoids treating an offscreen sizing clamp
as an application's minimum width. Staging rechecks desktop/window eligibility
and cancellation; gesture position batches use their existing direct path.

## Controls

Primary shortcuts use **Control + Option**. They use the focused managed window's
display, then the active ribbon; the pointer supplies a fallback when neither is
available. The dashboard can select another display explicitly. Direct switching
cancels gesture momentum and queued motion before revealing the selected column.

| Keys | Action |
| --- | --- |
| H / L | Focus previous / next column |
| Shift + H / L | Reorder focused column |
| Command + ← / → | Focus first / last column |
| 1–9 | Jump to column 1–9 |
| R | Cycle Half / Full width |
| F | Full width |
| T | Float focused window and restore its original frame |
| Q | Pause / Restore |

Control + Option + ← / → and Shift + ← / → are optional navigation/reorder aliases.
Earlier Control + Option + Command bindings remain for Half (2), Full (0), Float
(F), Pause / Restore (P), and Shift + arrows for reordering. Control + Option +
Command + arrows now select the first/last column; use H/L for previous/next.

The native menu and dashboard's **Keyboard shortcuts** section share one binding
catalog. Live status reports how many shortcuts registered, were received, and
were dispatched. A collision shows the unavailable shortcut and registration
status in both places; conflicting optional aliases do not disable working
navigation. If no previous/next bindings can register, live startup stops before
moving windows. Keyboard handling uses Carbon hot keys on the application event
loop and does not require Input Monitoring.

The isolated demo changes only shapes inside RibbonDesk. Its three-finger surface
uses local AppKit touches and the same inertia processor, without a global tap.

## Motion diagnostics

Choose **Record Motion Diagnostics (60 seconds)** from the status menu before a
test. **Stop Motion Diagnostics** saves it sooner. Capture otherwise stops after
60 seconds and retains at most 4,000 rows at:

```text
~/Library/Application Support/local.prototype.RibbonDesk/input-motion-diagnostics.json
```

Normal operation records nothing. A capture records event timing, contact counts,
deltas, release velocity, motion geometry, pointer/focus identity, and keyboard
dispatch counters. The transport also records per-window begin/end, per-app lane
duration, batch start/finish skew, write spans, and controller busy/coalesced ticks.
These measure request completion, not actual pixel presentation or display FPS.
It contains no screenshots, window titles, or document text.
The local file uses 0600 permissions. A new capture replaces the previous trace.
Use the timing trace alongside actual desktop testing to investigate brief jitter,
missed snaps, and transient focus errors that isolated snapshots can miss.

## Build and tests

macOS 13+, installed tools only, host architecture, no package downloads:

```sh
cd /Users/mtoro/Documents/Codex/2026-10-20/task/RibbonDesk
zsh Scripts/test-layout.sh
zsh Scripts/test-desktop.sh
zsh Scripts/test-shortcuts.sh
zsh Scripts/test-motion-transport.sh
zsh Scripts/test-window-resize.sh
python3 Tests/SigningChecks.py
zsh Scripts/build-app.sh
```

Normal builds require an explicitly selected existing signing identity. Configure
its public fingerprint and requirement mode with the workflow in
[Docs/DEVELOPMENT-SIGNING.md](Docs/DEVELOPMENT-SIGNING.md). Selection stays outside
the source tree; scripts neither create keys nor change certificate trust.
Missing identities fail before replacement, and signed output cannot silently
downgrade to ad-hoc. Disposable ad-hoc builds require explicit `--ad-hoc` and a
separate output path when the usual app is certificate-signed.

Changed-code fixtures check matching signer fingerprints, designated
requirements, and cross-requirement acceptance before migration. These checks
do not prove Accessibility approval survives a later rebuild; that needs a native
update test. Migration from the earlier ad-hoc app may require a fresh approval.
The app does not edit permissions or request Input Monitoring. Input startup
failure prevents tiling.

`build-app.sh --preview` builds `dist/trackpad-preview/RibbonDeskPreview.app`
with ID `local.prototype.RibbonDesk.preview`. Preview launches into the isolated
demo by default and does not arrange other apps. The explicit `--live` argument
uses the normal saved-arrangement flow; the canonical bundle also supports
`--demo`. The canonical ID is
`local.prototype.RibbonDesk`; fixture windows use `.test-windows`. Builds stage
and sign a fresh bundle, retaining the previous bundle in `.build/`. Tests use
standalone Swift runners and fake AX/input/displays; they post no OS input and
move no user windows. `swift-local.sh --disable-sandbox` applies only to SwiftPM's
manifest process, not to macOS security settings. Compiler caches stay in `.build/`.

## References and limits

[Paneru](https://github.com/karinushka/paneru) informed the gesture API, Mission
Control, app-animation handling, and parallel motion commits. See [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)
and [Docs/PANERU-NOTES.md](Docs/PANERU-NOTES.md). The earlier requested
[ChainYourMac website review](Docs/REFERENCE-REVIEW.md) is retained; the user later
chose separate strips per desktop, superseding its all-desktop gathering decision.
The current keyboard layout also takes inspiration from its
[shortcut reference](https://chainyourmac.com/#shortcuts), with H/L navigation,
numbered jumps, first/last selection, and width cycling adapted to RibbonDesk's
half/full layout.

Native clipping, stacks/tabs, spring physics, and automatic sleep recovery are
outside this update. A
surviving window can retain a pending restore if its app withholds its AX window
on an inactive desktop. No broad app-compatibility or notarization claim is made.
