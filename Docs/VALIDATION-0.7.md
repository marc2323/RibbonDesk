# RibbonDesk 0.7 validation

## Result and behavior

Three-finger horizontal swipes move the ribbon anywhere, with bounded inertia,
a display-linked 28 ms presentation filter, and animated edge snapping. New
swipes interrupt settling. The selected column aligns to its nearest screen edge
before receiving focus. Two-finger wheel/scroll events are outside the event tap
mask and retain the system route. RibbonDesk remains Swift/AppKit/SwiftUI.

Each desktop on each display retains its own strip, order, focus, and offset.
The user explicitly accepted this simpler model, superseding all-Space gathering.
Eligible windows are captured when a desktop is visited, with originals appended
before the first move. Native desktop membership is preserved. RibbonDesk's own
dashboard is included. Hidden/minimized windows remain unchanged.

The default speed is 2x, adjustable from 0.5x to 5x. In the final physical trial
the user also adjusted the speed to 1.25x. Inertia decays at 3.3/s for at most
1.5 seconds. Native gesture ends, staggered sliding releases, and a 70 ms quiet
fallback can start inertia. A fresh contact interrupts it. A strict old release
drift threshold was cancelling real flicks; the native trace exposed this and the
regression test now reproduces sliding 3-to-2-to-1-to-zero contact release.

Presentation smoothing filters raw contact timing without changing logical travel.
It has the same exponential response at 60 and 120 Hz, reverses immediately, and
converges exactly. Snapping starts at the displayed offset, avoiding a jump over
unpresented input. Width presets honor the dashboard's native minimum width.

## Checks and identity

| Check | Result |
| --- | --- |
| Pure layout/input runner | 15 checks, 4,547 assertions, zero failures |
| Production desktop view/input/controller with fake boundaries | 132 assertions, zero failures |
| Release | 0.7.0 build 7, arm64, ad-hoc signed |
| Preview identity | local.prototype.RibbonDesk.preview |
| Canonical identity | local.prototype.RibbonDesk |
| Fixture identity | local.prototype.RibbonDesk.test-windows |

Logs: [layout](layout-checks-0.7.log), [desktop](desktop-checks-0.7.log),
[release](release-build-0.7.log), [preview](preview-build-0.7.log),
[bundle registrations](bundle-registration-0.7.log).

Tests exercise exact edge alignment, monotone settling, interrupted snaps, release
drift, missing-end inertia, two-finger pass-through, bounded coalescing at different
refresh rates, AX animation-flag restoration/debt, delayed/cancelled moves,
per-desktop state, append-before-write, dashboard inclusion, closed-window
reconciliation, 22 windows on two simulated displays, negative/vertical display
layouts, display removal, persistence/recovery, and original-frame restoration.
Tests post no OS input and move no user windows.

No source-control repository exists in this directory. Prior source snapshots
are retained under .build/before-0.6, .build/before-0.7, and
.build/before-0.7-smoothing. Release/source archives retain previous versions.
The current source manifest is [source-sha256.txt](source-sha256.txt).

## Physical trials and evidence

The user rejected 0.6's feel: “Still jumpy or momentum is missing.” Automated
success was not treated as proof of smoothness. That build did verify native
independent desktops and its own dashboard column, and restored all eight visited
windows with zero frame error and unchanged memberships:
[own column](live-0.6-own-column.json), [restore](live-0.6-restored.json).

The first 0.7 trial confirmed snapping but remained jittery. Explicit local,
bounded diagnostics recorded event phases, contact counts, movement timing, and
snap/coast state without document contents. They showed inertia being cancelled
within milliseconds by sliding release contacts. Summary:
[first motion trial](live-0.7-first-motion.json).

After release-drift handling and smoothing, the user reported “Smooth enough
now.” Native traces confirmed ongoing coasting and completed edge settling.
The retained bounded trace includes a naturally completed 50-frame coast over
0.824 seconds, plus interrupted flicks/reversals and four completed snap
animations. Across its 791 AX position writes, median time was 1.62 ms, p95
5.81 ms, maximum 28.61 ms, with zero AX write failures. These are transport
measurements, not compositor frame times or a broad app benchmark.
[motion summary](live-0.7-motion.json).

The final trial visited desktops 1 and 3 on the built-in display. Sleep/lock
suspended control with the saved arrangement retained. After unlock, recovery
restored all six captured windows, with no pending records. Five frames matched
exactly; one Firefox window differed by one point. Every native desktop
membership was unchanged. [Restoration summary](live-0.7-restored.json).

The user chose to finish with the current display. Two-display support is covered
by fake-boundary tests and earlier hardware trials; this new motion build was not
physically retested with an external display. No trackpad settings were changed.
The same canonical Accessibility grant was refreshed after ad-hoc rebuilds; the
user completed macOS authentication when prompted. No other grant was changed.
One remote AX observation timed out; reconnecting the exact app succeeded. This
was not counted as an application crash or gesture failure.

The final width-constraint build was launched natively. Selecting the one-third
preset for RibbonDesk retained its 1,000-point native minimum, at x=376 with an
exact right edge of 1,376, fully inside the usable display. Desktop membership
stayed unchanged. [Minimum-width check](live-0.7-minimum-width.json).

The final process is live at the user's tested 1.25x speed. Temporary logging is
disabled by removing the explicit local marker before the final process starts. Raw traces and original-arrangement snapshots stay local
and are excluded from release/source ZIPs.

## Scope and limits

Window motion still depends on public AX transport and target apps, so universal
compositor-level smoothness is not claimed. The current native display topology
must match the saved one for restoration. Inaccessible hidden/minimized windows
retain pending records; visiting their desktop and retrying may be necessary.
Newly opened windows enroll on the next desktop capture, not continuously.
Stacks/tabs, native overflow clipping, spring physics, and automatic sleep
recovery are outside this update. Legacy private Space transfers remain only
for recovery of pre-0.6 snapshots; new sessions never gather desktops.

Paneru informed selected input, quiet-release, app-animation, and Mission Control
techniques. It is not bundled as a Rust engine. Its MIT notice is included in
source and app resources; see [PANERU-NOTES.md](PANERU-NOTES.md).
