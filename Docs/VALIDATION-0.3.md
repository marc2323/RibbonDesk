# RibbonDesk 0.3 validation — 2026-10-20

## Scope and reference

The current app remains an original Swift/AppKit/SwiftUI implementation. The
[ChainYourMac website](https://chainyourmac.com/) and its interactive browser demo
were inspected. Focus navigation was exercised in that demo. The site describes
a Rust window engine with SwiftUI, per-display strips, and direct swipe tracking.
No implementation source or assets were copied.

This update adds horizontal scroll capture anywhere during a live session,
independent per-display strip state, launch-time capture and tiling, persistent
original frames, and window accounting without the former 12-window limit.
Hidden/minimized windows remain unchanged, per the user's explicit preference.

The source tree has no Git repository. The preceding 0.2 source is preserved at
`.build/before-0.3/source.tar.gz`; the preceding signed bundle is retained by the
build script under `.build/previous-app.*`. Historical distribution archives remain
unchanged. Earlier evidence is in [VALIDATION-0.2.md](VALIDATION-0.2.md).

## Automated checks

| Check | Result |
| --- | --- |
| Pure geometry/input runner | 15 checks, 4,547 assertions, zero failures |
| Desktop runner | 81 assertions, zero failures |
| Canonical release build | Passed, 0.3.0 |
| Preview release build | Built with distinct identity |

Evidence: [layout-checks-0.3.log](layout-checks-0.3.log),
[desktop-checks-0.3.log](desktop-checks-0.3.log),
[release-build-0.3.log](release-build-0.3.log),
[preview-build-0.3.log](preview-build-0.3.log).

The desktop runner compiles the production input classifier, AppKit view,
controller, convergence helper, and persistence code. It uses fake AX, input-hook,
and display boundaries, plus a real temporary JSON file. It never posts OS events
or touches user windows. Coverage includes:

- Axis locking, slow fractional motion, zero-delta lift, quick reversal,
  cancellation, native momentum continuation, vertical pass-through, and callbacks queued
  before listener shutdown.
- Continuous pan without focus changes or size/convergence writes. Hundreds of
  input samples coalesce into bounded position batches. Finishing a gesture
  focuses once without pulling the final offset back to the old focused column.
- A new gesture supersedes settling/focus work queued by the previous lift.
- Native inertia begins after finger lift, continues at the OS decaying deltas,
  settles once, supports interruption by a vertical gesture, and has a bounded
  fallback for a missing momentum-end event. A speed control scales input.
- A manual window move is cached without polling writes and does not disable
  global scrolling; the next explicit strip action reconciles its position.
- Twenty-two windows across two displays, independent offsets, negative and
  vertically shifted display coordinates, display-seam bounds, and no dead zone
  at an unoccupied outside edge.
- Preserved dimensions for fitting windows, including the host's 1,855-point-wide
  maximized-window case. Launch tiling no longer forces a smaller outer inset.
- Snapshot saved before every initial write; automatic launch tiling; disk round
  trip, private file permissions, relaunch without overwriting pending recovery,
  successful rebinding/restoration, failed save, failed input hook, unreadable file.
  Recovery disambiguates equal parking frames by a unique saved title, and refuses
  ambiguous duplicate titles instead of restoring the wrong window. Missing AppKit
  launch dates use a public kernel process-start query; processes born after
  capture and known changed launch dates are rejected.
- Pause, write cancellation, queue draining before restoration, AX failure,
  display removal, preserving pending recovery on changed topology, and retry
  after restoring the display configuration.

These tests establish behavior at the boundaries. They do not measure hardware
input latency or establish broad target-application compatibility.

## Native dual-display test

Host: macOS 15.7.3, arm64, Swift 6.2.3, installed Command Line Tools. No packages
or toolchains were downloaded. The real connected displays were:

| Display | Global AX frame | Usable AX frame |
| --- | --- | --- |
| Gigabyte M32U | (0, 0, 1920, 1080) | (0, 25, 1856, 1055) |
| Built-in Retina Display | (417, 1080, 1440, 900) | (417, 1080, 1440, 900) |

The fixture creates two native windows on each display and one minimized window.
Its own JSON records frames and minimized state; it does not access other apps.
A fixture correction explicitly selects each target screen and lets the initial
minimization settle before recording originals.

The canonical app's existing Accessibility entry was refreshed after the ad-hoc
build, under the user's prior authorization. Other permission entries were not
changed. The global active scroll tap started using that Accessibility grant.
No Input Monitoring grant was requested.

On launch, the app saved the real current arrangement before tiling: seven
eligible windows from the host app, Finder, ForkLift, and the fixture, across both
displays. The dashboard reported the captured count and accounted-for unchanged
entries. The minimized fixture stayed minimized with the same frame. The first
exploratory pass rejected resizing the host's maximized window and restored all
originals. The final implementation preserves fitting dimensions; native launch
then remained live and an explicit restoration returned all seven original frames.

A controlled interruption sent SIGTERM only to RibbonDesk while its recovery file
was saved. The file remained byte-for-byte unchanged, and relaunch showed pending
recovery instead of overwriting it or arranging again. Six frames restored
initially; Finder exposed a missing AppKit launch date. The corrected build uses
the public kernel process-start time for that case and restored the remaining
Finder frame from the same snapshot. WindowServer independently confirmed all
seven original frames, the fixture geometry was exact, and its minimized window
stayed minimized. See [recovery-0.3-summary.json](recovery-0.3-summary.json) and
[live-0.3-recovered.json](live-0.3-recovered.json). This was an intentional SIGTERM
test, distinct from the earlier unproven remote UI signal-9 reports.

The persistent original-arrangement file is outside the project:
`~/Library/Application Support/local.prototype.RibbonDesk/original-arrangement.json`.
It contains local window titles, so its contents are not included in the source
archive or these diagnostic artifacts. Only disposable fixture geometry and
aggregate results are retained here.

The user physically tested horizontal scrolling away from the bottom bar on both
displays and reported: “scrolling works and feels smoother, but it can be a bit
faster, and include momentum.” The requested follow-up adds a 1.5× default speed,
a 0.5×–3× slider, and native momentum continuation. Its final hardware check is
in progress. CUA's horizontal scroll commands previously delivered zero X delta,
so hardware input is required for that check. See [native-input-probe.log](native-input-probe.log) for the
prior tool limitation. This limitation is not treated as a successful hardware test.

## Performance and limits

The old scroll path cancelled and restarted a full frame operation on every
sample, including AX/WindowServer readback and at least 32 ms of matched samples.
The new gesture path runs position-only writes on a dedicated worker queue,
coalesced by a 60 Hz timer. It performs no discovery, size writes, focus changes,
or frame convergence polling during finger movement or inertia. The event-tap callback
only classifies and queues input; it never calls AX.

Final geometry and restoration still receive bounded verification. Pause cancels
pending work and drains the position queue before restoring originals. A target
AX call can take up to 250 ms; this is not a vsync-locked compositor or a measured
60-fps guarantee. Public AX cannot clip native windows at display boundaries;
overflow parks with an edge handle and may overlap. Occupied display seams are
bounded to avoid covering the neighbor. Spaces and topology changes pause the
session; no cross-Space identity or restoration is claimed.

Current canonical executable SHA-256:

```text
4b2d997fd394994fe15caf8c5d235101d692c2caac197bc26be396303bb042f0
```
