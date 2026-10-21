# RibbonDesk 0.5 validation — 2026-10-20

## Delivered change

Exactly three trackpad contacts trigger horizontal ribbon movement anywhere in a
live session. Two-finger scrolling/navigation and native wheel momentum keep the
normal system route. The HID tap's event mask contains only AppKit gesture events;
scroll-wheel events are neither observed nor consumed. Vertical gestures and
other finger counts pass through. The dashboard/optional panel also stopped
forwarding wheel input to the ribbon. The isolated demo uses local three-contact
AppKit touch events, without an OS tap.

A pure contact processor matches NSObject touch identities, accumulates tiny
movement, chooses an axis, rejects replacements/count changes without centroid
jumps, and tracks the latest direction. A flick starts bounded exponential
inertia; new contacts stop it, reversal resets velocity direction, and focus
settles once. Momentum lasts at most 1.2 seconds. A missing end event has a 750 ms
fallback. Existing speed control, per-display gesture ownership, all-desktop
gathering, dashboard inclusion, private original-arrangement storage, and Space
restoration remain in place.

No macOS trackpad preferences were changed. Read-only defaults showed
three-finger horizontal gesture = 0, four-finger horizontal gesture = 2, and
Three Finger Drag = 0 for built-in and Bluetooth trackpad domains. The detailed
reference setup recommends four-finger desktop switching and two-finger page
navigation for three-finger ribbon control.

Source before this change: `.build/before-0.5/source.tar.gz`. The preceding native
Space/recovery evidence is preserved in [VALIDATION-0.4.md](VALIDATION-0.4.md).
This source directory has no Git repository.

## Automated checks and build

| Check | Result |
| --- | --- |
| Pure layout/input runner | 15 checks, 4,547 assertions, zero failures |
| Actual desktop view/input/controller with fake AX/displays | 111 assertions, zero failures |
| Canonical release | 0.5.0 build 5; release compiled, ad-hoc signature verified |
| Preview | Same new executable, separate `local.prototype.RibbonDesk.preview` ID |
| Launch Services | Exactly one canonical registration; preview and fixture IDs distinct |

Logs: [layout](layout-checks-0.5.log), [desktop](desktop-checks-0.5.log),
[release](release-build-0.5.log), [preview](preview-build-0.5.log),
[bundle registrations](bundle-registration-0.5.log).

Gesture cases include real NSEvent/NSTouch subclasses delivered to the production
adapter (including distinct equal identity objects), two-finger wheel/native
momentum pass-through, exact finger counts, tiny motion, vertical axis locking,
quick reversal, contact replacement, interleaved empty samples, invalid values,
hold-before-lift, end/cancel, bounded frame-rate-independent inertia, new two-finger
interruption, stop invalidating queued callbacks, and a missing-end fallback.
Existing fake-boundary tests still cover 22 windows/two displays, negative and
vertical display layouts, save-before-write, coalescing, restoration, interrupted
session recovery, and Space-transfer failure. Tests post no OS events and move no
user windows.

## Native check

On macOS 15.7.3 arm64, the signed canonical app successfully started the HID
gesture tap using its existing Accessibility permission after the authorized
signature refresh. It saved originals and gathered eight windows, including its
own dashboard. One physical display is connected; the user previously chose to
finish with this display. No additional permission was requested.

The known host compatibility issue reproduced when starting on Space 1: ChatGPT
returned to its original Space 3, and the app paused with originals retained.
See [initial paused session](live-0.5-initial-paused.json). This is the previously
documented desktop reassignment, not a gesture-classifier result. Restoration
then returned all eight enrolled windows to their exact original frames and Space
assignments: zero-point maximum frame error and zero pending originals. See
[restoration evidence](live-0.5-restored.json). Two temporary host windows that
failed eligibility were accounted for as unchanged and were never enrolled.

Remote Mission Control/Dock inspection timed out. The desktop overview was
closed afterward; its temporary WindowServer thumbnail transforms were excluded
from the final frame comparison. No signal-9/stdout_eof failure was reproduced.

Hardware three-finger flicks cannot be synthesized through the available UI tool.
A physical gesture check and two-finger app check were requested; they remain
unconfirmed. Restarting that test on the desktop containing ChatGPT needs the
user's desktop selection, because the remote selector timed out. Final current
state: RibbonDesk is paused, original arrangements restored, no input listener
registered. No new simultaneous external-display hardware result is claimed.

## Reference review

The requested sub-agent reviewed the homepage/demo and linked English feature,
setup, configuration, keybinding, comparison/migration/learning, privacy, and terms
pages. The findings and user-specific differences are recorded in
[REFERENCE-REVIEW.md](REFERENCE-REVIEW.md). In particular, the reference documents
3/4/5 fingers, default four, and retains per-Space strips. RibbonDesk deliberately
uses the requested three fingers and gathers all desktops. Full stacks/tabs,
dynamic enrollment, and a display-synced spring engine are outside this change.

Canonical executable SHA-256:

```text
8332170984aff3a064fce670b50b5f76086fbe270fba9ee8b29c04132c88cca4
```
