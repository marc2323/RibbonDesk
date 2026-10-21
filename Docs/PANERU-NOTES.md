# Paneru implementation notes — 2026-10-21

Reviewed upstream commit `12c58b2225a40e434053ea9343a41e2012466f9a`.
RibbonDesk remains a Swift/AppKit app, without a bundled Paneru process or Bevy.

- [Input](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/platform/input.rs): HID AppKit gesture events, contact identities/finger counts, and empty interleaved samples inform the input boundary. RibbonDesk retains its own classifier and explicit final/staggered-release handling.
- [Scrolling](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/ecs/scroll.rs): raw-contact inertia is separate from native wheel momentum, with bounded integration after stalls. RibbonDesk uses its own 70 ms missing-release fallback, amount-scaled exponential coast, and 120–200 ms settlement. At amount `a`, its decay is `5/a` and simulated duration is at most `a` seconds; Off bypasses inertia.
- [Parallel position commit](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/ecs/systems.rs#L1112-L1121): `commit_window_position` processes changed window positions using `par_iter_mut`, with an autorelease pool around each reposition. The commit lives in `src/ecs/systems.rs`, not `src/ecs/windows.rs`.
- [Native reposition](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/manager/windows.rs#L784-L790) calls the [AX position setter](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/manager/windows.rs#L596-L619). The [enhanced-UI guard](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/manager/windows.rs#L546-L590) shares state per PID and retains restoration responsibility across overlapping operations.
- [Mission Control](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/platform/mission_control.rs): Dock AX overview notifications avoid treating thumbnail transforms as real window geometry.

## RibbonDesk 0.11 transport

The 0.10 transport wrote every external AX position serially after immediately
moving its local dashboard. This made app delays accumulate and separated the
first and last window in a frame. It also restored/reborrowed the enhanced-UI
flag each batch.

The replacement uses concurrent per-PID lanes with ordering inside each app,
a main-thread lane for local AppKit work, and one shared completion barrier.
The controller retains only current/latest intent while busy. Enhanced-UI suppression lasts until
the session drains; transient reads retry and failed restoration remains owed.
Cancellation/error cannot return past the barrier while a native write is still
outstanding. Injected transport tests exercise these behaviors without AX access.

This adapts the concurrent-commit principle rather than adopting Paneru's ECS,
thread pool, or source implementation. It does not provide atomic presentation:
providers still service AX requests at different times, and the slowest lane can
delay the next frame. Begin/end and skew diagnostics support measurement without
claiming that successful AX completion means pixels appeared simultaneously.

## Live-only second pass

The first native 0.11 trial remained jittery despite nearly simultaneous request
starts. Further upstream review found model and pacing differences beyond the
parallel commit:

- [Event pump, lines 715–719](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/ecs/systems.rs#L715-L719) explicitly avoids waiting a display-frame period before accepting input. Its normal schedule still performs one synchronous parallel commit barrier; no hidden asynchronous AX pipeline or atomic foreign-window transaction was found in this path.
- [Active-swipe layout, lines 1758–1796](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/ecs/layout.rs#L1758-L1796) directly assigns positions instead of chasing them with a second window animation.
- [Scroll constraints, lines 338–356](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/ecs/scroll.rs#L338-L356) round the shared strip origin before deriving member positions.
- [Offscreen layout, lines 1712–1724](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/ecs/layout.rs#L1712-L1724) parks only wholly offscreen windows. The [default sliver](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/config.rs#L493-L494) is 5 coordinate points.
- [Focus-triggered neighbor raising](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/ecs/focus.rs#L533-L568) is separate from position commits. The [native API comment](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/manager/windows.rs#L316-L318) explicitly limits cross-application AX raising. Its targeted `verify_window_position` system is a correction path, not an all-window readback on every input sample.

RibbonDesk's second pass removes the 18 ms presentation chase during direct
input/coast, rounds one common native offset, and retains the latest-input batch
barrier. Snap animation still uses the owning display's clock. Partly visible
windows now track their ideal position until fully outside and then retain a
5-point handle. Motion no longer raises windows; final layout retains best-effort
stacking. These are testable live-window changes, not a native smoothness claim.
Screen-capture/proxy research is paused; no Screen Recording access or capture
implementation was added.

Further review found Paneru's explicit
[offscreen resize staging policy](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/manager/windows.rs#L260-L278)
and [bounded resize retries](https://github.com/karinushka/paneru/blob/12c58b2225a40e434053ea9343a41e2012466f9a/src/manager/windows.rs#L793-L838).
That helper addresses partial width growth. RibbonDesk's native build 12 exposed
a different offscreen sizing failure: parked half-width requests were interpreted
as minimum-size constraints and promoted to full width. Build 13 uses a safe
same-display stage before settled offscreen resizing, verifies size, then parks.
The native startup kept all six windows half width, and the user subsequently
reported smoother motion and correct focus in a scoped trial. This does not
establish universal jitter-free behavior or atomic AX presentation.

## API and desktop boundaries

Position setters use the public Accessibility API and local movement uses
AppKit. `AXEnhancedUserInterface` is an existing undocumented attribute workaround,
not a permission grant. No new private SkyLight position/transaction call or
global WindowServer update suppression was introduced. Existing private Space
interop remains isolated to desktop identity and older transfer-aware recovery.

Each native desktop/display keeps its own strip. New sessions capture active
desktops and never transfer memberships. Original frames append before first
movement. The upstream MIT notice remains in source and app resources. Source
review informs design and does not establish RibbonDesk's native smoothness.
