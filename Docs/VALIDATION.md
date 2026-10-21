# RibbonDesk 0.11 validation — 2026-10-21

## Change and scope

The user reported increased jitter and windows moving out of sync in 0.10. This
update replaces the serial transport and revises frame pacing; it does not tune
motion settings to stand in for a transport fix. Half/full widths, the 8-point
gap, full usable height, short-flick snapping, pointer focus after settlement,
and per-Space/per-display isolation remain.

External apps receive one frame concurrently through per-PID serial lanes.
Windows in one process retain their order. Local AppKit operations run on main
and join the same all-lane completion barrier. The second pass removes raising
from motion batches; final settled layout retains best-effort stacking. The enhanced-UI flag
is leased through motion and restored after all outstanding writes finish.
Transient capability reads retry; failed restoration remains owed for retry.
Raise-only work does not acquire a lease.

The controller permits one frame in flight and coalesces busy updates into
one latest-intent follow-up. Direct input and coast use the next main-runloop
turn; the display clock drives settlement. One common strip offset is rounded
before native frames are derived. Committed geometry advances after the full barrier;
cancelled targets become unknown until reconciled. The frame clock stays on the
gesture-owning display. Hot-path geometry avoids native inventory and topology
polling. Notifications invalidate Space/overview/display changes; final native
validation still precedes focus. The dashboard miniature publishes completed
geometry at most 15 Hz independently of window transport.

## Source comparison and API boundaries

Upstream Paneru commit `12c58b2225a40e434053ea9343a41e2012466f9a` uses
[`commit_window_position` in `src/ecs/systems.rs`, lines 1112–1121](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/ecs/systems.rs#L1112-L1121)
with concurrent `par_iter_mut` commits. Its
[window implementation](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/manager/windows.rs#L546-L619)
uses per-PID enhanced-UI guards and AX position setters. RibbonDesk adapts the
concurrent-commit principle with GCD application lanes and its existing Swift
controller. See [Paneru notes](PANERU-NOTES.md).

Motion uses public AX position setters and AppKit. The existing
`AXEnhancedUserInterface` attribute is undocumented. Existing private Space
interop is unchanged; there is no new private WindowServer positioning,
transaction, or global update-suppression API. A shared completion barrier is not
an atomic pixel transaction. Providers can still complete/present at different
times, and the slowest outstanding call can delay the next frame.

## Retained 0.10 timing baseline

A bounded local diagnostics capture retained 4,000 rows covering 10.79 seconds,
with 250 render batches containing 649 AX position calls. The values below are
request-completion timings, not visual frame timing or pixel synchronization.
Raw captures and process IDs remain private and outside release archives.

| AX completion measure | Median | p95 | Maximum |
| --- | --- | --- | --- |
| Per-batch write span | 5.58 ms | 26.86 ms | 122.59 ms |
| Multi-app finish skew | 3.45 ms | 18.51 ms | 50.48 ms |

One successful AX call took 117.42 ms. Aggregate render intervals also contain
idle pauses and gesture boundaries, so their median is not reported as display
FPS. The baseline supports investigating serial delay; it does not establish
that the new build improves smoothness. The first 0.11 native trial below did not resolve the reported jitter.

The new transport retains baseline-compatible `move` rows and adds explicit
operation begin/end, per-app lane duration, batch start/finish skew and write
span. Controller rows include planning time, busy ticks, and completed offsets.
Diagnostics remain explicit, local, bounded to 60 seconds/4,000 rows, and off in
normal operation.

## Build 13 automated verification

The settled resize correction passed the central checks below. Each suite is
counted once; build 11/12 results are history and are not added to this total.

| Check | Result |
| --- | --- |
| Pure layout/motion | 35,897 assertions, zero failures |
| Real AppKit/controller with fake AX/displays/input | 268 assertions, zero failures |
| Isolated concurrent transport | 28 assertions, zero failures |
| Isolated settled resize policy/sequence | 70 assertions, zero failures |
| Shortcut registration/dispatch | 16 assertions, zero failures |
| Signing workflow with mocked OS tools | 19 checks, zero failures |
| Automated total | 36,298 checks/assertions, zero failures |
| Canonical release build | Passed; production compilation 15.67 seconds |
| Preview release build | Passed; production compilation 0.21 seconds |
| Canonical/preview signature verification | Strict deep verification passed |
| Build 12 → 13 signing continuity | Same certificate/designated requirement; mutual cross-checks passed |
| Build 13 native arrangement/approval continuity | First launch reached Live; all six default half widths, existing grant retained without Settings |
| Build 13 user motion/focus | User reported “Smoother; focus correct” after slow drag, flick, reversal and pointer-focus trial |
| Build 13 recovery | All six original frames restored within 1 point; zero pending after one retry when Activity Monitor became available |

[Core log](layout-checks-0.11-build13.log),
[desktop/controller log](desktop-checks-0.11-build13.log),
[transport log](motion-transport-checks-0.11-build13.log),
[resize policy/sequence log](window-resize-checks-0.11-build13.log),
[shortcut log](shortcuts-checks-0.11-build13.log), and
[signing workflow log](signing-workflow-0.11-build13.log). Core, transport, shortcut,
and signing suites retain their passing results on unchanged sources; their
copied logs are not additional runs or assertions. Build evidence:
[canonical release](release-build-0.11-build13.log),
[preview release](preview-build-0.11-build13.log), and
[changed-build signing continuity](signing-continuity-0.11-build13.log).

The sizing checks use the production policy/executor with an injected native
model that rejects resizing at a parked origin. The negative control reproduces
the rejection; safe resize-before-park keeps half width. Checks cover both edges,
fractional/negative display origins, true minimum sizes, aborted operations,
cancellation, and no staging during position-only movement. The controller
regression uses that same executor: all six default columns stay half width,
originals remain recoverable, and a genuine 1,000-point minimum still promotes
only its own column. These tests use injected sizing; native startup evidence is
reported separately below.

## Build 13 native startup

The canonical app reached Live on the first attempt after replacing build 12,
without a permission or Settings refresh. A native CG geometry audit showed all
six windows at **924 × 1,055 points** on the 1,856-point usable-width display.
Notion, Firefox, ChatGPT and Activity Monitor were parked at x = −919, y = 25,
retaining the intended 5-point handle. ForkLift was at x = 0 and RibbonDesk at
x = 932, both y = 25, preserving the 8-point gap and full usable height.
The raw audit and per-window identifiers remain private.

This verifies the initial half-width arrangement and usable height for those six
windows. Startup geometry alone does not establish synchronized presentation.

The user then tried a slow drag, flick, reversal and pointer-focus selection and
reported **“Smoother; focus correct.”** This is a positive native result for the
tested desktop and interactions. It is not a universal jitter-free claim, a
pixel-presentation measurement, or broad application compatibility evidence.
The bounded native trace retained 4,000 rows over 8.567 seconds. All 189 recorded
strip offsets and 254 external x requests were integral. Four completed snaps
ended exactly on target, with no reversed or overshooting recorded steps; one
snap was interrupted by a new gesture. No raise occurred during a gesture/snap.
The maximum observed native batches in flight was one. Two batches were marked
cancelled alongside new gestures; all recorded external AX write statuses were
successful.

All four immediate native focus readbacks matched their requested window.
However, all four pointer checks used the fallback path (`hit = false`), so this
trace does **not** independently verify successful cursor hit-testing. The scoped
user report and native identity agreement are distinct evidence.

Batch request-completion p95 was 14.252 ms in this capture versus 22.985 ms in the
first 0.11 capture. The captures contain different gestures, application counts
and lane mixes; the second also starts mid-batch. This is observational timing,
not a controlled benchmark, a pixel-synchronization result, or display FPS.

On Pause, the five available windows restored while minimized Activity Monitor
correctly stayed pending. After making Activity Monitor available, one Restore
Saved Arrangement retry completed recovery with **zero pending**. Native CG
geometry matched all six originals within one point: four exact, Firefox and
ChatGPT within one point. Activity Monitor was returned to its minimized state
afterward. Raw diagnostics, window identities and original frames remain private.

## Build 12 verification and native outcome

The integrated live-only second pass passed the central checks below. Counts are
one result per suite; earlier attempts and repeated runs are not added again.

| Check | Result |
| --- | --- |
| Pure layout/motion | 35,897 assertions, zero failures |
| Real AppKit/controller with fake AX/displays/input | 260 assertions, zero failures |
| Isolated concurrent transport | 28 assertions, zero failures |
| Shortcut registration/dispatch | 16 assertions, zero failures |
| Signing workflow with mocked OS tools | 19 checks, zero failures |
| Automated total | 36,220 checks/assertions, zero failures |
| Native launch/Accessibility continuity | Existing grant retained without visiting Settings; initial Firefox geometry failure paused safely, retry reached Live |
| Native arrangement | Four parked apps incorrectly promoted to full width; two visible columns stayed half |
| Native motion/focus trial | Not performed because the default layout was incorrect |
| Native recovery | All six originals restored, zero pending, in both sessions without restart |

[Core log](layout-checks-0.11-build12.log),
[desktop/controller log](desktop-checks-0.11-build12.log),
[transport log](motion-transport-checks-0.11-build12.log),
[shortcut log](shortcuts-checks-0.11-build12.log), and
[signing workflow log](signing-workflow-0.11-build12.log). The unchanged transport
and shortcut suites retain their verified passing results; their copied logs do
not represent extra runs or additional assertions.

New controller checks cover direct input during a blocked native batch,
finish-during-flight settlement from the completed offset, integer common frames,
final stacking, and restoration. Strict freshness checks cover eligibility
refusal, exact identity, persistent failure, no hot-path refresh, and Space/overview
revalidation after asynchronous resolution. These use real AppKit with fake
system boundaries and do not establish native presentation quality.

## Verified first-pass checks

These historical results belong to the first transport pass and are preserved
alongside its original logs. They are not added to later-build totals above.

| Check | Result |
| --- | --- |
| Pure layout/motion | 35,829 assertions, zero failures |
| Real AppKit/controller with fake AX/displays/input | 231 assertions, zero failures |
| Isolated concurrent transport | 28 assertions, zero failures |
| Shortcut registration/dispatch | 16 assertions, zero failures |
| Signing workflow with mocked OS tools | 19 checks passed |
| Automated total | 36,123 checks/assertions, zero failures |
| Release compilation | Passed in 17.50 seconds |
| Native changed-code signing fixtures | Same certificate/requirement, different CDHashes, mutual requirement checks passed under default trust |
| Canonical/preview build and native signing | Pending final results |
| First native 0.11 motion trial | User reported “still jittery”; issue remains open |
| Native focus, recovery, and approval continuity | Pending separate verification |

[Core log](layout-checks-0.11.log), [desktop/controller log](desktop-checks-0.11.log),
[transport log](motion-transport-checks-0.11.log), [shortcut log](shortcuts-checks-0.11.log),
and [release compile log](release-compile-0.11.log). Repeated desktop verification
runs are not added again to the total.

Transport checks prove another app starts while one injected call is blocked,
same-PID order, one gesture-long flag lease, transient-read retry, restoration-debt
retry after a lane error, cancellation/drain waiting for outstanding work,
main-thread local operations, per-lane raise order, skipped superseded frames,
and complete finite timing metrics. These inject work and never call native AX,
post input, move windows, or change preferences.

Controller checks cover one shared barrier, latest-intent pacing, bounded preview
updates, no gesture-path inventory, cancellation-cache invalidation, and immediate
Space/overview/topology invalidation alongside prior layout, focus, and recovery
regressions. These use real AppKit with fake system boundaries.

## Signing workflow

Builds require a configured existing identity instead of silently producing a new
ad-hoc identity. Public signer selection is stored privately outside the source
package. A changed-code fixture workflow compares signer fingerprints and
requirements and checks cross-acceptance before replacing an app. See
[development signing](DEVELOPMENT-SIGNING.md).

The 19 mocked workflow checks cover selection, failure paths, signer extraction,
requirements, and continuity checks without accessing keys. Separately, two
changed disposable executables were signed using the user-created local
certificate under default trust. They had the same leaf certificate and
designated requirement, different CDHashes, and passed both mutual requirement
checks. The [native fixture log](signing-identity-checks-0.11.log) records that
result. Identity configuration remains outside the project.

These fixtures prove code-signing continuity for that signer, not retained
Accessibility approval. Separately, the changed build 12 native launch retained
its existing Accessibility grant without Settings. Build 12 → 13 actual changed-code
signing continuity passed, and build 13 also retained its grant and reached Live
without Settings. Migration from an earlier ad-hoc build may
need a fresh approval. No private key, trust setting, or permission database is
included in the release source.

## First native 0.11 motion attempt

The user tested the first live build and reported **“still jittery.”** That
transport-only attempt was not accepted or packaged as a completed smoothness fix.
A private capture retained 4,000 rows over 6.984 seconds, including 175 batch
metric rows and 374 AX position calls.

| Request-completion measure | Median | p95 | Maximum |
| --- | --- | --- | --- |
| Cross-app request start skew | 0.018 ms | 0.150 ms | 15.581 ms |
| Cross-app completion skew | 6.143 ms | 20.305 ms | 33.925 ms |
| Batch write span | 7.122 ms | 21.136 ms | 34.733 ms |
| AX position call | 2.058 ms | 16.197 ms | 34.702 ms |

Controller planning p95 was 0.110 ms and queue wait p95 was 0.083 ms. Within-gesture
render-request intervals had median 9.623 ms and p95 28.400 ms. These are request
and completion times, not measured pixel presentation or a display-FPS claim.
The extra 0.11 telemetry increases row volume, so its retained duration differs
from the 0.10 baseline. This is not a controlled before/after visual benchmark.

Concurrent starts worked at the request level, while app completion still varied.
The user result prevents treating request concurrency alone as a solution.
Further live-window model/pacing, quantization, parking, and stacking experiments
are described below. Screen-capture/proxy research is paused; no Screen Recording
access has been requested or capture code added.

## Live-only second pass — scoped native result

Direct/coast updates no longer chase input through the 18 ms presentation filter.
They submit latest intent on the next main-runloop turn while preserving one
in-flight native barrier. Every placement derives from one rounded strip offset.
Finishing during a pending batch waits for its completed offset before building
the snap, avoiding a return to the prior completed start. Mid-motion AX raising
is removed.

Parking now begins only when a window's ideal frame is wholly outside the
viewport. Until then, its native x follows the shared grid, even when fewer than
5 points remain visible. Fully parked windows retain a 5-point handle. Height,
half/full widths, the 8-point gap, endpoint restoration, and owning-display seam
constraints remain. The central core suite passed 35,897 assertions with zero
failures after this geometry change. The full integrated automated total is
36,298 passing checks/assertions after the build 13 sizing correction below.
Build 12's native attempt was blocked by false full-width promotions. Build 13's
native startup kept all six columns half width, and the user reported smoother
motion and correct focus in the scoped trial above.

Stale AX objects also receive a bounded boundary correction. Missing geometry or
`invalidUIElement`/`cannotComplete` can trigger one strict fresh lookup and one
retry after motion drains. Refresh requires the exact saved process/native window
number, bundle/launch identity, unique matching AX native number, and current
eligibility. The new hook never selects by title or geometry, transfers Spaces,
or refreshes on the motion path. Controller records replace the refreshed object
so subsequent motion does not reuse it. Existing broader crash recovery remains
unchanged. Focus eligibility failures can use this only for the exact saved native
window still present on the active Space/display. Persistent failures leave the
original arrangement pending.

Build 12 exposed a separate offscreen sizing issue: moving to a 5-point parked
origin before resizing caused rejected/partial size results to be interpreted as
native minimum widths. Four parked apps were promoted to full, while the visible
ForkLift and local dashboard stayed half. Build 13 stages a required offscreen
resize within the same owning usable display, validates the size, then parks at
the final origin. A safely visible original resizes before parking. Staging
rechecks active Space/display, membership, eligibility, visibility, overview and
cancellation before writes and after awaited sizing before constraint learning.
Stage/resize failures keep the original record pending. Motion position batches
never use this path. Optional `resize-step` diagnostics record requested/AX/CG
geometry and opaque timing IDs; titles/content are excluded and capture is off
by default. Native startup verifies half-width sizing for the six tested windows;
the scoped motion/focus trial was positive, and all six originals restored within
one point after making the minimized window available for one retry.

The complete first-pass report is preserved in
[VALIDATION-0.11-FIRST-PASS.md](VALIDATION-0.11-FIRST-PASS.md). The later positive
user trial does not change that historical first-pass result.

## Native status and limits

Before replacement, all six original captures from the prior 0.10 live session
were resolved and its app quit. This is recovery evidence for that preceding
session, not a native recovery test of 0.11.

The first native 0.11 session also eventually restored all six originals with no
pending records, after restarting the exact same build to obtain fresh AX objects
and manually retrying one remaining ForkLift size failure. This exposed the stale
proxy recovery issue; it does not verify the new bounded-refresh implementation.

Build 12 retained Accessibility approval across the changed build and restored
all six originals without restarting, but its false full-width promotions
prevented a meaningful motion trial. Build 13 reached Live with six half-width,
full-height columns and retained approval. The user reported smoother motion and
correct pointer focus after the scoped test. Build 13 restored all six originals
within one point, leaving minimized windows pending until available.
Multiple-display motion and broad application compatibility remain unverified;
native AX presentation remains non-atomic. The first native 0.11 gesture trial
remained jittery; that evidence is preserved. Historical
[0.10 validation](VALIDATION-0.10.md) and release archives remain unchanged.
