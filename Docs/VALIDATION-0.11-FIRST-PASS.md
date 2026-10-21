# RibbonDesk 0.11 validation — 2026-10-21

## Change and scope

The user reported increased jitter and windows moving out of sync in 0.10. This
update replaces the serial transport and revises frame pacing; it does not tune
motion settings to stand in for a transport fix. Half/full widths, the 8-point
gap, full usable height, short-flick snapping, pointer focus after settlement,
and per-Space/per-display isolation remain.

External apps receive one frame concurrently through per-PID serial lanes.
Windows in one process retain their order. Local AppKit origin/raise operations
run on main and join the same all-lane completion barrier. Prevalidated boundary
raises share the batch, without a second CG inventory pass. The enhanced-UI flag
is leased through motion and restored after all outstanding writes finish.
Transient capability reads retry; failed restoration remains owed for retry.
Raise-only work does not acquire a lease.

The controller permits one frame in flight and coalesces busy display ticks into
one latest-intent follow-up. Committed geometry advances after the full barrier;
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

## Automated verification so far

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
Accessibility approval. Canonical app signing and approval continuity across
changed app builds remain pending. Migration from the earlier ad-hoc build may
need a fresh approval. No private key, trust setting, or permission database is
included in the release source.

## First native 0.11 motion attempt

The user tested the live build and reported **“still jittery.”** The change is not
accepted as a smoothness fix and has not been packaged as a completed release.
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
are under investigation. Screen-capture/proxy rendering remains a separate
proposal; no Screen Recording access has been requested or capture code added.

## Native status and limits

Before replacement, all six original captures from the prior 0.10 live session
were resolved and its app quit. This is recovery evidence for that preceding
session, not a native recovery test of 0.11.

The first native 0.11 gesture trial remained jittery. Cursor focus, actual
per-app presentation, live restoration, multiple-display behavior, and permission
continuity still need their own scoped observations. Historical
[0.10 validation](VALIDATION-0.10.md) and release archives remain unchanged.
