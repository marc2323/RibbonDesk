# RibbonDesk 0.9 validation — 2026-10-21

## Behavior

The production ribbon now starts with half-screen columns. Two halves and their
12-point central gap fit the usable display width exactly; a full-width column
occupies two grid positions. Dragging remains continuous, while release and
keyboard focus settle on the same half-screen pitch. Focus reveal keeps the
selected column fully visible without moving it off the grid. Odd tails and
mixed half/full widths use grid-aligned endpoints.

Tiled windows request the full usable display height, excluding the macOS menu
bar and Dock. Native minimum widths promote a half to full; apps that cap their
height retain a shorter supported height. A window that cannot fit a supported
slot restores its own original frame and becomes floating, leaving the other
columns active. Each native Space and display retains its own ribbon, order,
widths, focus, and offset.

Lifting selects the nearest column and activates it after momentum and settling.
Keyboard shortcuts and column selection interrupt previous motion. The normal
Half/Full controls use keys 2/0; legacy keys 1/3 map to Half/Full.

## Motion and smoothness

The dashboard provides saved Speed (0.5×–5×), Sensitivity (0.5×–2×), Acceleration
(0%–100%), and Momentum (Off–100%) controls. Defaults are 2×, 1×, 15%, and 35%.
Sensitivity changes the activation threshold without scaling subsequent travel.
Zero acceleration gives linear travel. Momentum preserves the lift velocity and
scales both duration and distance; at normal refresh the default coasting cap is
0.525 seconds of simulated motion, 100% allows 1.5 seconds, and Off proceeds
directly to settling. Each integration step is capped at 50 ms to bound jumps;
scheduling stalls can therefore extend wall-clock duration. Reset Defaults
restores all four settings.

The gesture path sends position changes through the existing serial AX motion
queue. Display-linked batches contain only the active display. They perform no
window resizing, app activation, discovery, or convergence polling during finger
movement. New contact and direct window commands interrupt old motion. The
28 ms presentation filter and current-position snap handoff remain in place.

## Automated verification

| Check | Result |
| --- | --- |
| Pure layout and motion | 22 layout checks plus 27 motion assertions; 35,591 assertions, zero failures |
| Production AppKit/controller/input with fake boundaries | 175 assertions, zero failures |
| Total | 35,766 assertions, zero failures |
| Canonical release | 0.9.0 build 9, arm64, ad-hoc signed; strict signature verification passed |
| Isolated preview | 0.9.0 build 9, separate local.prototype.RibbonDesk.preview ID; strict signature verification passed |

[Pure layout and motion log](layout-checks-0.9.log),
[desktop/controller/input log](desktop-checks-0.9.log),
[release build](release-build-0.9.log), [preview build](preview-build-0.9.log),
[bundle identities and signature checks](bundle-registration-0.9.log).

Grid regression coverage includes exact half-pair fit, full usable height,
half/full mixtures, odd tails, continuous movement, stable focus reveal, native
minimum rounding, empty/single/invalid/tiny geometry, floating windows, reorder,
reconciliation, and 1,200 mixed operations at fractional and negative display
origins. The earlier freeform checks remain. Motion checks cover bounded settings,
persistence decoding, speed applied once, sensitivity without altered travel,
linear and accelerated input, momentum Off and amount, continuous lift velocity,
frame-rate independence, and reset behavior.

Production-controller regression covers native width promotion, full-height
fallback, oversized-window floating, exact grid settlement and activation,
isolation across Spaces and displays, saved recovery, cancellation, and latest
intent. Explicit sidebar and keyboard selections stop production momentum and
invalidate queued callbacks, so old motion cannot override a quick switch.
Desktop tests instantiate real AppKit views/controllers with fake AX, displays,
input, and persistence boundaries; they access no user windows and post no OS
input.

## Native preview check

The separately identified preview was exercised in its isolated demo. Motion
controls adjusted successfully, Momentum Off worked, and Reset Defaults returned
the expected values. Half/Full changed the miniature map; selecting Planner
settled at offset 1,452, exactly two 726-point pitches. Dark appearance header and
miniature-map contrast were corrected and checked again. A compact dashboard
kept its controls reachable through scrolling.

The final signed preview was launched again after the final build and opened
Demo only. Selecting Planner and choosing Full produced width 1,440 and offset
2,178, exactly three 726-point pitches. Restarting the isolated demo restored
half width 714 and offset zero. At 613 points wide, the native compact miniature
map and controls fit visibly. The preview was left open in Demo only.

This native check did not arrange real user windows, test global trackpad
input, or change permissions. It verifies the app's own UI and demo, rather than
physical gesture feel or broad target-app compatibility. Historical live-window
evidence remains in [0.8 validation](VALIDATION-0.8.md) and earlier reports.

## Limits

Public Accessibility transport and each target app still constrain presentation
smoothness. Overflow columns keep reachable edge handles and may overlap while
parked; occupied display seams keep them inside the owning display. Unsupported
native window sizes may remain floating. No new physical multiple-display,
global-gesture, live restoration, notarization, or broad compatibility claim is
made for this version.
