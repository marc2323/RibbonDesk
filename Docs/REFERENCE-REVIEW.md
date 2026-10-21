# ChainYourMac reference review — 2026-10-20

A requested sub-agent reviewed the English homepage, feature demos, FAQ, setup,
configuration/keybinding guides, linked comparison/migration/learning pages, and
privacy/terms. It exercised focus, stack, and tab controls in the browser demo.
No native ChainYourMac binary was installed or tested; no source/assets copied.

| Area | Intended reference behavior |
| --- | --- |
| Gesture | Configurable 3/4/5 fingers or Off; four is default. Follow fingers horizontally, then glide toward the nearest column. Configurable natural direction. Exact inertia physics are unspecified. |
| Setup | For three-finger input: desktop switching uses four fingers, page navigation two, Three Finger Drag off. Its listener cannot prevent macOS also recognizing the same configured swipe. Vertical Mission Control/App Exposé remain available. |
| Layout | Maintained columns; newly opened windows join beside focus without resetting other widths. Gaps, Dock awareness, width presets, full width, pinning, stacks, tabbed columns, drag ordering. |
| Displays/Spaces | Independent strip per physical display **and per native Space**, retaining focus/offset. Send windows to another display; optionally disable displays. Hide overflow before a window crosses an adjacent display seam. |
| Focus/motion | Keyboard reveal, optional centering, focus border/dimming, focus-follows-mouse, mouse-follows-focus. Background windows avoid stealing focus. Display-synced spring motion (documented 500 ms, damping 0.9). |
| Persistence | Managed order, widths, stacks, and tabs persist across restarts. Quit brings offscreen windows onscreen. Exact restoration of the pre-launch frames/Space assignments is not clearly promised. |

Sources: [homepage/features](https://chainyourmac.com/#features),
[setup](https://chainyourmac.com/setup),
[configuration](https://chainyourmac.com/niri-config-macos),
[keybindings/gestures](https://chainyourmac.com/niri-keybindings-mac),
[OmniWM comparison](https://chainyourmac.com/chainyourmac-vs-omniwm),
[quit behavior](https://chainyourmac.com/komorebi-for-mac).

One older [Rectangle comparison](https://chainyourmac.com/chainyourmac-vs-rectangle)
sentence says “two-finger,” contradicting the detailed setup/configuration pages.
The latter consistently document three or more fingers and take precedence. The
browser demo accepts ordinary sideways scrolling and cannot establish the native
app's finger discrimination. The footer credits the Rust [Paneru](https://github.com/karinushka/paneru)
engine (MIT); RibbonDesk is Swift/AppKit/SwiftUI with a small Objective-C Space bridge.

## RibbonDesk decisions

User instructions deliberately differ from the reference: gather eligible windows
from **all** desktops, include RibbonDesk's own dashboard, save exact original
frames/desktop membership, leave hidden/minimized windows unchanged, and use
**three** fingers while preserving two-finger system behavior. Keep those choices.

0.5 implements the requested gesture distinction and retains momentum and the
per-display routing from previous updates. Actual contact identities come from
AppKit gesture events at a HID event tap. Primary API usage was checked against
[Touch-Tab's SwipeManager](https://github.com/ris58h/Touch-Tab/blob/master/Touch-Tab/SwipeManager.swift)
and [Paneru's input handler](https://github.com/karinushka/paneru/blob/main/src/platform/input.rs).
RibbonDesk uses its own centroid/axis/velocity implementation, not those algorithms.

Full reference parity would also require dynamic enrollment, stacks/tabs, sleep
recovery, and display-synced spring animation. These remain outside this gesture
update. Reference claims were read on this date; they are not test evidence for
RibbonDesk.

## Updated desktop decision — 0.6

The user subsequently accepted separate strips per desktop. This supersedes the
all-Space gathering decision above. New sessions preserve native desktop
membership; RibbonDesk remains included on its own desktop, hidden/minimized
windows remain unchanged, and originals are saved before movement.

## Native motion and permissions — 2026-10-21

ChainYourMac's current [official setup](https://chainyourmac.com/setup) explicitly
requires Accessibility only: no Screen Recording, Input Monitoring, or SIP
changes. Its [privacy policy](https://chainyourmac.com/privacy) says it does not
read window/screen contents. The developer also states that it uses no scripting
addition in the [SIP comparison](https://chainyourmac.com/yabai-without-sip).

The [homepage architecture section](https://chainyourmac.com/) describes a SwiftUI
interface over a Rust background engine, with a vsync-locked spring and shortcuts
handled directly by the engine. The [configuration guide](https://chainyourmac.com/niri-config-macos)
documents the display-synced spring and credits MIT-licensed
[Paneru](https://github.com/karinushka/paneru). Chain itself is listed as closed
source in its [official comparison](https://chainyourmac.com/chainyourmac-vs-omniwm).
Its exact modified engine revision, AX write scheduling, and current fork are
unpublished in the inspected sources; upstream Paneru is not proof of identical
Chain implementation. These are publisher statements, not native test results.

RibbonDesk's next motion pass remains Accessibility-based. The capture-surface
research is unimplemented and deferred following the user's preference to avoid
Screen Recording; no additional permission is requested.
