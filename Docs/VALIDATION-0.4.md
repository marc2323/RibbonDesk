# RibbonDesk 0.4 validation — 2026-10-20

## Delivered behavior

The current Swift/AppKit/SwiftUI app gathers eligible windows from all ordinary
macOS desktops onto the active desktop of each connected display. The dashboard
is enrolled and moves/focuses directly through AppKit. Hidden/minimized windows
remain unchanged. Frame and original desktop membership are saved before the
first transfer. Private Space APIs are isolated in `Spaces.swift` and a small
Objective-C `SpaceInterop` target; no external packages, injection, privileged
helper, SIP changes, or additional permissions are used.

Source before this update is preserved in `.build/before-0.4/source.tar.gz`.
Previous evidence is in [VALIDATION-0.3.md](VALIDATION-0.3.md). Historical release
archives remain intact. There is no Git repository in this source directory.

## Automated checks

| Check | Result |
| --- | --- |
| Pure layout/input | 15 checks, 4,547 assertions, zero failures |
| Production desktop runner with fake AX/input/displays | 100 assertions, zero failures |
| Canonical release | 0.4.0, built and signature verified |
| Preview | Separate `local.prototype.RibbonDesk.preview` identity |

See [layout-checks-0.4.log](layout-checks-0.4.log),
[desktop-checks-0.4.log](desktop-checks-0.4.log),
[release-build-0.4.log](release-build-0.4.log), and
[preview-build-0.4.log](preview-build-0.4.log).

Existing global gesture/momentum, 22-window/two-display, negative/vertical display,
coalescing, cancellation, geometry convergence, and persistence tests continue to
pass. Added cases cover inactive-desktop candidates, save-before-transfer,
partial-gather failure, return to original Spaces, retained pending IDs after a
failed Space restore, closed windows versus inactive windows, unsupported staged
windows leaving no ghost column, legacy 0.3 JSON compatibility, fullscreen target
rejection, and late Space-change notifications during restoration. These are
boundary tests and do not establish actual WindowServer transfer behavior.

## Native cross-desktop test

Host: macOS 15.7.3 arm64. Three ordinary desktops existed (Space IDs 1, 3, 4),
with eligible windows on 1 and 3. Only the built-in display was connected for this
update. The user chose to finish with that display. The previous dual-display
hardware result remains documented in VALIDATION-0.3.md; the new transfer path
has not received a simultaneous dual-display native test.

The first discovery pass proved that Firefox and Notion withhold AX windows on
inactive desktops. The app now stages non-minimized WindowServer candidates,
saves their original identity/frame/Space, transfers them, and resolves the exact
AX identity. It returns unsupported candidates. No Screen Recording grant was
used to obtain metadata; no application document contents are included here.

The legacy Hammerspoon-style compatibility transfer was rejected or silently
ignored by this host. The app detected that through membership verification and
stopped. The replacement asynchronous bridged WindowServer operation worked.
It resolves its local symbol from the already loaded SkyLight Mach-O image; no
process memory is modified. References for the API declarations/operation are
[Hammerspoon spaces](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/libspaces.m),
[the newer operation](https://github.com/Hammerspoon/hammerspoon/pull/3889), and
[yabai's implementation](https://github.com/asmvik/yabai/blob/master/src/space_manager.c).

The native session gathered ten CG window IDs onto desktop 3: Notion, two Firefox
windows, ChatGPT, Finder, ForkLift, Terminal, two disposable windows, and the
RibbonDesk dashboard. All ten were independently observed on that desktop and
onscreen. RibbonDesk's own column focused successfully, as did a Firefox window
that came from desktop 1. Pause restored all ten original Space memberships and
frames; maximum frame error was 2 points. The disposable minimized window stayed
minimized. Evidence: [live-0.4-gathered.json](live-0.4-gathered.json) and
[live-0.4-restored.json](live-0.4-restored.json).

## Interrupted-session recovery

A deliberate SIGTERM targeted only the canonical RibbonDesk process after the
snapshot had been saved. The snapshot stayed byte-identical after termination
and after relaunch. Relaunch opened paused rather than overwriting originals or
tiling again. Nine surviving external windows returned to their original frames
and desktops; the terminated process's dashboard was retired. Zero pending IDs
remained. See [recovery-0.4-summary.json](recovery-0.4-summary.json).

The first recovery attempt encountered a delayed desktop-change notification.
Restoration is now allowed to continue across Space notifications, since it
validates all-Space identity/membership; sleep/display changes still cancel it.
Production-controller regression tests cover a notification during a delayed
restore, ignoring stale notifications whose actual desktop IDs match, and pausing
when the current desktop IDs really differ. Layout uses all-Space identities
because on-screen flags can lag a completed native transfer; an additional
regression simulates this delay. The final signed build repeated the interruption/relaunch/restore test successfully
without retries. All nine surviving windows had exact original frames (zero-point
maximum error), correct original desktop membership, and zero pending IDs.

An early failed transfer also exposed two temporary host UI windows that closed
before recovery. Their original data was retained, and closed-window retirement
now uses the all-Space CG inventory rather than treating them as inaccessible
forever. The prior recovery file and a copy annotated with staging provenance
were preserved privately in `.build/before-0.4/`; no original frames were removed.
These local files contain window titles and are excluded from source archives.

## Observed application compatibility limit

Tests started on desktop 1 observed the ChatGPT host window return to desktop 3
after its initial verified transfer. Other managed windows remained on desktop 1.
RibbonDesk detected the missing on-screen window, paused control, and retained
recovery. Whether the reassignment comes from the host's automation integration
or application behavior was not established. This remains a compatibility limit;
we do not claim reliable capture of an application that reassigns its own desktop.

The final native run started on the working desktop (3), gathered all ten eligible
windows, stayed live, and passed interruption recovery. The final production
session excludes the disposable fixture and preserves original frames/Spaces.

An exploratory Mission Control/Dock UI lookup timed out; subsequent native UI
calls worked. No unexpected signal-9/stdout_eof process failure was reproduced.
The two deliberate canonical-process SIGTERM tests are identified separately.

## Limits

The Space transfer path depends on private macOS APIs and can break on an OS
update; absence/no-op is detected and recovery retained. Fullscreen desktops,
hidden/minimized windows, dialogs, fixed-size windows, exclusions, and unsupported
AX identities remain outside the strip. Displays must match the saved topology
for restoration. Ordinary Space changes pause active control; restoration can
return windows to inactive desktops. Native compositor clipping, dynamic window
enrollment, z-order/focus restoration, and broad app compatibility are unproven.

The existing native momentum/1.5× speed implementation is retained. The user
reported the single-desktop implementation works fine. CUA horizontal scroll
commands deliver zero X delta, so they are not claimed as a new hardware swipe
measurement. Input and motion architecture remains covered by local tests.

Canonical executable SHA-256:

```text
e737675eecda7d2744e514ad103141d99b21536972d5d31005f93631006dc509
```

Final state: eight user windows (including RibbonDesk) are live on desktop 3;
original frames and Space IDs are saved. Disposable fixtures were closed. See
[live-0.4-final-session.json](live-0.4-final-session.json). The preview and fixture
have distinct bundle IDs; Launch Services lists exactly one canonical identity.
See [bundle-registration-0.4.log](bundle-registration-0.4.log).
