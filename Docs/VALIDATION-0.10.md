# RibbonDesk 0.10 validation — 2026-10-21

## Behavior

The air gap is 8 points, reduced from 12. Two half-width columns still fit the
usable display exactly. Full usable height, native size constraints, and ribbons
isolated by native Space and display remain part of the layout.

Gesture settlement follows the final viewport offset independently of old focus.
A deliberate short flick reaches the next half-screen boundary; a small slow drag
chooses the nearest boundary. Release intent requires at least 8 points of direct
travel and aligned release velocity of at least 180 points/second. Generated
momentum is excluded from direct travel and is not projected twice. Reversals
against net travel, noise, cancellation, and strip endpoints cannot force an
extra slot. Interrupting an unfinished snap uses the next boundary beyond its
current position rather than skipping a second slot.

Final matching contact positions are consumed before release, allowing a baseline
plus one lift sample and staggered 3-to-2 finger releases to register. Stationary
lift samples retain fresh release velocity. Genuine two-finger and vertical
input stay outside ribbon control.

After final frames apply and outstanding motion drains, pointer focus checks the
managed window beneath the current pointer against both planned and actual
frames. Eligible hits activate and raise that window. Gaps and unmanaged areas
fall back to the nearest column. Pointer selection preserves the settled offset.
Keyboard switching activates immediately and cancels gesture work.

## Motion and overlap handling

The presentation filter is 18 ms instead of 28 ms. A monotonic ease-out settles
over 120–200 ms without crossing its target. Reversing discards unpresented
travel in the previous direction. Coasting preserves lift velocity, with a
firmer decay and a simulated duration cap equal to the momentum amount in
seconds: 25% permits 250 ms, default 35% permits 350 ms, and 100% permits one
second. Integration steps remain capped at 50 ms; scheduling stalls can extend
wall-clock duration. Existing saved speed, sensitivity, acceleration, and momentum
values are unchanged.

Position writes follow travel direction so leading windows move first. Visible
columns are raised above parked columns when membership changes, without
activating another app during the swipe. Parking stays inside the owning display
at occupied seams. These mitigate overlap; public Accessibility cannot atomically
move or clip app surfaces, so they do not guarantee compositor-level presentation.

## Keyboard and diagnostic changes

Control + Option + H/L focuses previous/next. Shift + H/L reorders, 1–9 jumps to a
column, R cycles Half/Full, F selects Full, T floats, and Q pauses/restores.
Control + Option + Command + arrows select first/last. Optional arrow aliases
and earlier width/float/pause/reorder bindings are listed in the shared catalog.
The native menus and dashboard use that same catalog. Registration collisions
produce visible warnings; an unavailable optional alias does not disable working
navigation. Startup fails before tiling if previous/next navigation is unavailable.

The status menu offers an explicit 60-second timing capture and early stop.
Captures retain at most 4,000 rows in the private local diagnostics file, including
input, motion, pointer/focus, and shortcut events. Normal operation records
nothing. Capture does not include screenshots, titles, or document contents.

## Automated verification

| Check | Result |
| --- | --- |
| Pure layout and motion | 22 layout checks, 27 motion assertions, 237 gesture-settlement assertions; 35,829 assertions, zero failures |
| Production AppKit/controller/input with fake boundaries | 213 assertions, zero failures |
| Shortcut registration/dispatch checks | 16 fake-backend assertions, zero failures |
| Automated total | 36,058 assertions, zero failures |
| Native keyboard receiver | Three exclusive keys registered; physical H/L/R each received and dispatched once while another app was active |
| Canonical release | 0.10.0 build 10, arm64, ad-hoc signed; strict deep signature verification passed |
| Isolated preview | 0.10.0 build 10, separate preview ID; release build and strict ad-hoc signature verification passed |
| Canonical native startup | Live session, six captured windows, enabled controls, 29 shortcuts registered; observed usable-height geometry |
| Canonical live keyboard trial | User confirmed “Shortcuts work”; six native events received and dispatched |

Pure regression scenarios cover the user's existing 1.05× speed, 0.7× sensitivity,
10% acceleration, and 25% momentum; one- and two-sample flicks; release-only and
staggered releases; stationary lift; quiet holds; noise; slow drags; reversals;
vertical and two-finger rejection; cancellation; endpoints; interrupted snaps;
focus-independent targeting; no doubled momentum; 8-point exact fit; monotonic
settlement; and equivalent 60/120 Hz smoothing. Earlier layout, recovery, width,
floating, and 1,200 mixed-operation scenarios remain in the suite.

The [core log](layout-checks-0.10.log) records the successful pure checks. Its test
runner accesses no user windows, posts no OS input, and changes no preferences. The [desktop/controller/input log](desktop-checks-0.10.log) covers
pointer focus at final frames, right-half hits, pointer movement during settling,
gap/panel fallback, display ownership, frontmost keyboard routing, production
short flicks, no-motion contacts, reversal, directional write order, bounded
stacking, actual parked-overlap/topmost outcomes, activation isolation,
other-display/floating preservation, boundary-only raises, diagnostics, and
existing recovery paths. These use real AppKit views
and controllers with fake AX, displays, input, and persistence boundaries.

The [shortcut log](shortcuts-checks-0.10.log) covers catalog completeness and unique
IDs, registration retention, exactly-once dispatch, separate receipt/dispatch
counters, unknown/stale event rejection, repeated teardown, optional collisions,
mandatory navigation failure rollback, installation failure, and deinitialization.
Its injected backend does not register OS shortcuts or post input.

The separate five-minute native receiver registered three exclusive Carbon hot
keys. With another app active, the user physically pressed Control + Option + H,
L, and R. The visible receiver showed **3 shortcuts ready · 3 received · 3
dispatched**, with **H: 1, L: 1, R: 1** and 3:04 remaining. This verifies global
keyboard delivery and exactly-once dispatch through the production Carbon path
without connecting an AX bridge or moving/focusing user windows. Earlier short
receiver attempts were inconclusive and are not used as final delivery evidence.

The [canonical release log](release-build-0.10.log), [preview build log](preview-build-0.10.log),
and [bundle identity/signature log](bundle-registration-0.10.log) record successful
0.10.0 build 10 arm64 bundles with distinct canonical/preview identifiers and
strict deep ad-hoc signature verification. In the isolated native preview, Control + Option + L selected Workshop;
Control + Option + R changed it to width 1,440 at offset 724 once, then returned
it to half width 716. Control + Option + 3 selected Reading room at offset 724.
The compact 613-point dashboard map and updated shortcut help were checked.
These checks exercised the preview's own UI, without arranging real user windows.
Physical trackpad feel remains separate from preview and build verification.

## Native launch and limits

The canonical 0.10 app launched live after its existing Accessibility entry was
refreshed. Its native dashboard showed Live session, six captured windows,
enabled controls, pointer-focus help, and **29 shortcuts ready**. Counters were
zero at launch; during the subsequent physical trial they reached **6 received
and 6 dispatched**, without synthetic actions increasing them. The user
confirmed **“Shortcuts work”** in this canonical desktop trial. Cursor-after-swipe
focus and physical motion feel remain unconfirmed. Native CG geometry showed
1,055-point usable-height tiles on a 1,080-point display.

This confirms live startup and observed tiling. The user confirmation establishes live shortcut switching alongside the six
received/dispatched events. It does not establish cursor-after-swipe focus or
physical trackpad smoothness. The separate physical H/L/R receiver verifies the
exact keys and once-per-key global delivery.

No new physical trackpad, multiple-display motion, live focus, live restoration,
or broad app compatibility claim is made by the pure checks. A continuous timing
capture and the user's next desktop test are needed to judge transient jitter and
the feel of fast swipes. The native keyboard receiver verified global key delivery without arranging
user windows. Restoration of the preceding 0.9 live session is not treated as
0.10 live recovery evidence.

Historical evidence remains in [0.9 validation](VALIDATION-0.9.md) and earlier
reports. Existing 0.9 validation and release artifacts have been preserved. This report is
also saved as [0.10 validation](VALIDATION-0.10.md).
