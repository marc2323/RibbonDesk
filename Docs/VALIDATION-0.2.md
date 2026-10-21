# Validation record — 2026-10-20

## Source and build reconciliation

This folder has no Git repository. Existing sources, tests, scripts, metadata,
and documentation were saved to `.build/before-horizontal/source.tar.gz` before
changes. The original app was built at 14:04; trackpad source and a preview were
modified around 16:02–16:04. Work continued from those newer sources.

The original 0.1 executable SHA-256 was
`5aec7a5e1ae33875e8c4f89749e77fb208f87c83d5e9cf2b7413cd17012a5f4e`.
The former preview executable was
`32a44596ce33faf5fe18f1216a0a4455fb392d9a518bdc31015198dde658b18a`.
The old 0.1 distribution archives remain unchanged. The former preview is also
saved as `dist/archive/trackpad-preview-before.zip`.

Both apps originally used `local.prototype.RibbonDesk`. CUA explicitly rejected
bundle-ID lookup as ambiguous. The preview was unregistered and archived.
The canonical app is now `dist/RibbonDesk.app`, version 0.2.0, with the original
bundle ID. `build-app.sh --preview` produces `RibbonDeskPreview.app`, named
RibbonDesk Preview, with ID `local.prototype.RibbonDesk.preview`.
Launch Services lists one canonical entry and one distinct preview entry.
See [bundle-registration.log](bundle-registration.log).

Builds sign and verify a fresh staged bundle, then move it into place. They avoid
overwriting a signed executable inode and retain preceding bundles under
`.build/previous-app.*` for rollback. Reopening the menu-bar app now opens its
dashboard; an ordinary first launch still starts disabled with only a status item.

## Environment

- macOS 15.7.3 (24G419), arm64; Apple Swift 6.2.3.
- Command Line Tools, macOS SDK 26.2; deployment target macOS 13.
- No package dependencies, downloads, toolchain installation, or global setting changes.

## Automated checks

| Check | Result |
| --- | --- |
| `zsh Scripts/test-layout.sh` | 15 checks / 4,547 assertions / 0 failures |
| `zsh Scripts/test-desktop.sh` | 34 assertions / 0 failures |
| Release build | Passed; `zsh Scripts/build-app.sh` |
| Separate preview build | Passed; `zsh Scripts/build-app.sh --preview` |
| Bundle metadata | Both Info.plist files pass `plutil -lint` |
| Signatures | Both bundles pass `codesign --verify --deep --strict` |

Evidence: [layout-checks.log](layout-checks.log),
[desktop-checks.log](desktop-checks.log), [release-build.log](release-build.log),
[preview-build.log](preview-build.log).

Desktop checks compile the production AppKit scroll view and controller without
the application entrypoint. In-memory NSEvent subclasses are delivered directly
to `scrollWheel(with:)`; no OS input is synthesized. Fake AX, shortcut, and display
providers exercise the real controller and queued commits. Production still uses
the actual display list and requires exactly one display. Coverage includes:

- Disabled input, slow fractional motion, gesture axis locking, zero-delta finger
  lift, cancellation, phase-less wheels, momentum phases, and gesture reset.
- Demo panning without revealing old focus, preserved widths, nearest-column focus.
- Live intent accumulation, convergence of every enrolled window, no activation
  while panning, one focus on lift, and ignored momentum.
- Pause before queued commits, original-frame restoration, shortcut removal,
  late events after pause, and restoration after an injected AX failure.
- Delayed target responses, superseding in-flight writes, cancellation during a
  pending response, and preventing quit until asynchronous restoration completes.
- The actual convergence helper with a brief target echo, an older animation,
  a bounded deadline returning actual geometry, and cancellation.

These tests do not establish actual target-app AX behavior or physical trackpad latency.

## Native desktop inspection

The canonical release was launched and its dashboard and isolated demo inspected.
Startup was disabled. The demo Accessibility state exposed offset 0 / Notebook
and later offset 698 / Planner. Demo does not access external windows.

Initial CUA app selection by full path timed out when the accessory app had no
dashboard window. Sampling showed its main thread idle in the normal AppKit event
loop. Reopening now exposes the dashboard successfully. No signal 9 / stdout_eof
failure was reproduced; there is insufficient evidence to attribute the earlier
failures to one cause.

The disposable fixture records raw native scroll events. CUA left/right commands
delivered zero horizontal delta, including a ten-page command; a vertical command
delivered y = -500. See [native-input-probe.log](native-input-probe.log).
Automated native horizontal commands therefore cannot establish physical
trackpad behavior in this environment.

## Real-window test

Two disposable native windows are supplied by
`zsh Scripts/build-test-windows.sh`. The fixture records its own original and
current frames in `.build/fixture-frames.json`; it does not access other apps.
Other running apps are excluded from RibbonDesk's test capture.

Initial live review stopped because Accessibility access was missing. The switch
was enabled but stale after an ad-hoc rebuild. Show in Finder verified its path;
the user explicitly approved removing and re-adding only the canonical app.
Refreshing that entry allowed capture of exactly two disposable windows.

The first real layout exposed an immediate-readback bug. Fixture history showed
an in-progress move (24,242 → 19,199), while back-to-back size/position requests
did not retain the requested size. The controller stopped and restored both
original frames, verified in [live-initial-restored.json](live-initial-restored.json)
and [live-initial-history.json](live-initial-history.json).

The first asynchronous attempt exposed an AX target echo: AX getters briefly
reported the target while the actual windows remained at the old positions.
Resizing there was clamped to heights 658/688; both windows were restored again.
See [live-ax-echo-restored.json](live-ax-echo-restored.json).

The fix awaits bounded asynchronous frame convergence between position and size
requests, requiring both AX values and WindowServer bounds to match. Independent
windows run concurrently; new intent cancels obsolete
continuations before their next write. Restoration also awaits verified frames,
and quit remains blocked while restoration is running. Reads yield for 16 ms
between attempts, with a 600 ms bound per phase; no animation setting is changed.

With WindowServer verification, live layout and left/right navigation succeeded.
The two real windows retained widths of 894 points, reached x = -440/466 at
offset 456, and returned to x = 16/922 at offset 0. See [live-right.json](live-right.json)
and [live-left.json](live-left.json). Fixture history then recorded several further
back-and-forth gesture sweeps. A final small sweep timed out and restored both
originals. The display configuration also changed to two displays during this
period, so that final failure cannot be attributed confidently to one cause.

The final source requires agreement across successive readback samples and
permits one bounded correction if an older target-app animation leaves the latest
frame wrong. It never retries indefinitely. New intent cancels that correction.

The final build was granted Accessibility access and tested with only the built-in
Retina display active. Capture confirmation enrolled exactly the two disposable
windows. The user performed physical two-finger scrolling in both directions,
including the requested quick reversal, and replied “Scrolled both directions.”
The session remained live. Between [live-final-start.json](live-final-start.json)
and [live-final-gesture.json](live-final-gesture.json), the fixture recorded 272
frame notifications: the first window traversed x = -440 through 16 and the second
x = 466 through 922. Every recorded frame retained width 894 and height 763.

Pause / Restore then returned both windows exactly to their original geometry:
(24, 242, 894, 528) and (458, 212, 894, 528). The dashboard reported “Paused. All
surviving captured windows were restored; no shortcuts remain registered.” See
[live-final-restored.json](live-final-restored.json) and
[live-checks.log](live-checks.log). RibbonDesk was quit after restoration. The
disposable fixture was also stopped; CUA selection timed out after its first
window closed, so its dedicated test process was terminated during cleanup.

These results establish the live scroll and restoration path for two standard
Cocoa windows on this desktop. Physical latency was not measured. No production
signing, notarization, multi-display, Spaces-transition, or broad app compatibility
claim is made by these results.

Current canonical executable SHA-256:

```text
2a1b80f5336a343413af149080b832b3fcec581740c1b8050b6734ec5c1d80d0
```
