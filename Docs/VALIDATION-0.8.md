# RibbonDesk 0.8 validation — 2026-10-21

## Fix

System Settings was explicitly excluded by the default bundle-ID list. The
default is now empty, so its eligible standard window joins the ribbon. Explicit
user exclusions, hidden/minimized windows, dialogs, and unsupported fixed-size
windows still retain their existing behavior.

The reported RibbonDesk window was already enrolled on native desktop 1, while
the active strip was desktop 3. The user chose to keep it on its own desktop.
No gathering, sticky-window policy, or Space transfer was introduced. Discovery
now handles all visible titled normal RibbonDesk windows, excluding NSPanel
status/utility surfaces, rather than requiring one dashboard identifier. Normal
windows from the separate accessory-policy preview app are also eligible for AX
discovery; the preview retains its distinct bundle ID.

A new idle check compares WindowServer identities on active desktops, filtering
hidden/minimized and excluded applications. An unchanged identity set causes no
AX traversal. If the set changes, discovery waits for swiping, coasting, snapping,
and layout to finish, then reconciles the desktop. New originals append to the
private recovery file before movement. Existing originals and relative column
order remain intact. New/reopened windows join in about one second while idle;
closing a column removes it without pausing other strips.

The 0.7 gesture, smoothing, momentum, snapping, and per-display behavior is
unchanged. Earlier physical motion validation is preserved in
[VALIDATION-0.7.md](VALIDATION-0.7.md).

## Verification

| Check | Result |
| --- | --- |
| Pure layout/input | 15 checks, 4,547 assertions, zero failures |
| Actual desktop/controller/input with fake boundaries | 141 assertions, zero failures |
| Total | 4,688 assertions, zero failures |
| Canonical release | 0.8.0 build 8, arm64, ad-hoc signed |
| Preview | 0.8.0, separate local.prototype.RibbonDesk.preview ID |

Logs: [layout](layout-checks-0.8.log), [desktop](desktop-checks-0.8.log),
[release](release-build-0.8.log), [preview](preview-build-0.8.log),
[bundle identities](bundle-registration-0.8.log).

The new regression covers default Settings inclusion, no rediscovery for stable
idle checks, no rediscovery during a swipe, late window enrollment, save before
write, preservation of earlier originals/order, a late-created local dashboard,
close/removal, and complete recovery. Existing gesture, interruption, desktop,
display, width-constraint, and recovery cases also pass. These automated tests
post no OS events and move no user windows.

## Native check

On the built-in display, the canonical app captured five initial columns,
including System Settings and RibbonDesk. Selecting Settings moved it to
x=661, width=715: exactly the usable right edge at 1,376. Revealing RibbonDesk
moved its own column to x=0, width=1,080. Both were fully visible and retained
their native desktop membership.

Closing Settings removed its column automatically. Reopening it created a new
native window identity, which automatically rejoined without switching desktops
or restarting the session. Its original was appended; every earlier original
was retained unchanged. [Enrollment evidence](live-0.8-enrollment.json).

The session visited desktops 1 and 3 and saved eight window records. Pause
restored all seven surviving windows, retired the closed Settings window, and
left zero records pending. Five surviving frames matched exactly; two Firefox
frames differed by one point. All desktop assignments remained unchanged.
[Restoration evidence](live-0.8-restored.json).

The final session is live at the user's tested 1.25x speed, with both Settings
and RibbonDesk listed in their desktop's ribbon. The same canonical Accessibility
grant was refreshed after rebuilding; no other permission or trackpad setting
was changed. No preview app was launched for this trial. The explicit temporary
input-diagnostic marker remains absent. Private raw audits/snapshots remain in
.build and are excluded from release/source archives.

The current trial used the built-in display. Multiple displays are covered by
simulation and earlier hardware trials; no new external-display physical trial
or repeated gesture-feel claim is made for 0.8. New-window discovery starts only
while idle, but may briefly wait on a target app's AX response. The existing
saved-topology and pending-recovery limitations remain documented in README.
