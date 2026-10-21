# Temporary capture surface: public API feasibility

Status: unimplemented and deferred following the user's preference to avoid
Screen Recording. No new permission is authorized or requested. Current work
investigates native Accessibility motion using ChainYourMac/Paneru references.

Research/design only. No capture API has been called, no pixels collected, no
permission requested, and no production change made for this investigation.

## Finding

A single RibbonDesk-owned compositor surface can animate window images together
while the native windows remain stationary, then reveal the real windows after
one final layout. This removes independently responding apps from the animation
loop. It does not make Accessibility moves atomic, guarantee zero capture
latency, or synchronize the capture times of several windows. Window contents
would be temporarily frozen during a gesture; content interaction resumes at
handoff. This is a feasible experiment, not yet a verified solution.

## Public API support

| Need | Public route | Boundary |
| --- | --- | --- |
| One window, including occluded/offscreen content | `SCContentFilter(desktopIndependentWindow:)` | Window-only filter excludes child/pop-up windows. Minimized window streams pause. |
| Background without duplicated native windows | `SCContentFilter(display:excludingWindows:)` | Exclude every managed window plus the overlay; remaining visible desktop, floating/unmanaged windows, Dock/menu content are part of the background. |
| macOS 14+ still images | `SCScreenshotManager.captureImage(contentFilter:configuration:)` | Async `CGImage` result; no public multi-image atomicity or latency guarantee. |
| macOS 13 | `SCStream`, stop after first usable complete frame | More stream lifecycle and buffer management. Initial product fallback should retain native AX motion until independently validated. |

The installed public SDK marks ScreenCaptureKit/filter APIs macOS 12.3+ and
SCScreenshotManager macOS 14+. Apple describes window streams as independent of
display and Space, including full content while occluded or fully offscreen;
minimization pauses delivery. Those statements apply explicitly to streams;
one-shot behavior still needs native checks with the same filters.
[Apple: advanced capture and window behavior](https://developer.apple.com/videos/play/wwdc2022/10155/)

Apple's screenshot API uses the stream configuration/filter model and returns
asynchronously. Separate requests should not be treated as one atomic desktop
snapshot. Cold enumeration/capture and warm capture must be measured rather than
assigned an assumed latency.
[Apple: screenshot API](https://developer.apple.com/videos/play/wwdc2023/10136/),
[Apple: captureImage](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage(contentfilter:configuration:completionhandler:))

Display exclusion filtering is the important background route: merely painting
window images over a raw display screenshot leaves their old positions visible
behind the moving images. The clean background must exist before an overlay is
shown. Cropping it to the usable display rect leaves system UI outside the
surface. Explicitly set `showsCursor = false`, `capturesAudio = false`, SDR BGRA,
and a fixed output resolution. On macOS 14, `ignoreGlobalClipSingleWindow = true`
can prevent partially offscreen windows from being clipped.
[Apple: display exclusion filter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:excludingwindows:)),
[Apple: global clipping](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/ignoreglobalclipsinglewindow)

## Explicit permission path

This route adds Screen Recording access, separate from existing Accessibility.
It does not need Input Monitoring, microphone access, Remote Desktop permission,
a persistent VNC capture entitlement, private WindowServer calls, or SIP changes.

Keep the feature off by default. Its Enable action should explain that temporary
images of ribbon windows and the display background are used only for motion,
with no app-created image files, uploads, or audio capture. Before enabling:

1. Check `CGPreflightScreenCaptureAccess()` without prompting.
2. Only after the person's explicit Enable action, invoke
   `CGRequestScreenCaptureAccess()` if needed.
3. Let macOS present its consent/Settings UI and let the person approve directly.
4. Recheck on app activation; leave the feature off if unavailable. If this OS
   requires an app restart, restore/pause normally before restarting.
5. Do not enumerate `SCShareableContent` before this permission step, because
   enumeration itself can initiate authorization. Never reset or write TCC.

Apple documents the preflight/request APIs and recommends them for authorization
state instead of inferring access from window metadata.
[Apple DTS: supported authorization APIs](https://developer.apple.com/forums/thread/839069?answerId=898801022),
[Apple: preflight](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()),
[Apple: request](https://developer.apple.com/documentation/coregraphics/cgrequestscreencaptureaccess())

Include a plain `NSScreenCaptureUsageDescription` in a future capture-enabled
build. Apple's current overview recommends the system content-sharing picker.
Picker consent is scoped to the selected filter; it should not be presented as
permission to enumerate and capture arbitrary other windows. Our automatic
window/background filter combination needs an explicit, reviewed authorization
choice. The sample also notes that a restart can be needed after permission.
[Apple: ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit),
[Apple: sample permission setup](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)

## Proposed capture and handoff contract

Use a capture-provider abstraction and a state machine:
`native → preparing → presenting → committing → native`.

A session token contains generation, display ID/topology revision, Space ID,
window `(pid, windowID)` identities, and layout revision. Validate the whole token
before accepting each callback, before presentation, and before native commits.
Space/display change, Mission Control, lock, permission loss, closed/minimized
window, external focus change, explicit keyboard/sidebar action, pause, or quit
invalidates the token, cancels pending work, hides the overlay, and releases
images. Late callbacks are discarded and released. Screenshot cancellation does
not promise to cancel the OS capture; generation checks must handle late results.
Because independent-window capture is Space independent, this guard is essential.

Prepare a clean background and all images needed by the visible motion range.
Show nothing until the set is complete, fresh, and still matches the session.
Never block the main thread for enumeration or capture. If preparation misses
its measured deadline, use native motion for that gesture. Do not switch halfway
into an incomplete capture surface. A cache miss during a long/fast traversal
needs an explicit native handoff before missing content is exposed; do not show
blank regions or silently limit navigation. This is a prototype acceptance gate.

Use one nonactivating display-local panel with one layer/Metal transaction for
all image transforms. The overlay must not become the focused window or appear
in its own capture. Ordinary click-through is unsafe while shown: depicted and
native window positions differ. A pointer-down must trigger deterministic
handoff/cancellation, without synthetic click forwarding. Keyboard shortcuts
cancel the overlay before their existing explicit-focus action runs.

At settle, compute the final slot layout and pointer target; commit native
frames while the overlay covers them. Require successful frame convergence and
two stable display ticks before removing the overlay and activating/raising the
pointer target. Public APIs provide no atomic fence across unrelated apps, so
native handoff quality remains a measured risk. A bounded timeout restores
native presentation; failures must never strand hidden or moved-away windows.

## Memory and data limits

Proposed initial bounds: one active display, at most two capture requests in
flight, at most one retained image per window plus a reserved replacement, and
128 MiB of accounted image bytes (`bytesPerRow × height`) including background.
Reserve before requests; evict unneeded neighbors first and reduce capture scale
or decline the surface when the whole visible set will not fit. Apply a separate
256 MiB budget for owned capture/render allocations and measure actual RSS/GPU
use; framework/WindowServer allocations cannot be asserted to fit that estimate.
A macOS 13 stream provider must explicitly bound its queue and retained buffers.

Retain no images across a Space switch, pause, quit, permission loss, or expiry.
No encoders, image exporters, clipboard writes, disk frame caches, network
transmission, window titles, or pixels in diagnostics. Log only opt-in bounded
numeric timing/status counters. OS-managed virtual memory is outside an app's
promise of no explicit image file writes.

## Isolated validation plan

First build a mock-only coordinator test target with no ScreenCaptureKit calls,
no Accessibility bridge, and synthetic colored image handles. Inject a virtual
clock, fake capture provider, fake renderer, fake native committer, and byte
budget. Do not add a test that implicitly requests permission.

Required cases:

- Independent completions arrive out of order; only one complete matching set
  presents, and all transforms share one presentation tick.
- Old callbacks after cancellation, Space change, display change, ID reuse,
  closure, or permission revocation never present or move/focus windows.
- Preparation timeout and partial/blank capture fall back without an overlay.
- Rapid reversal/new gesture invalidates the preceding generation; stale commits
  and stale pointer-focus callbacks cannot run.
- Memory reservation caps concurrency and allocation; one oversized/large-window
  set fails cleanly; replacement and cancellation release all owned handles.
- Fast traversal beyond cache coverage hands off before a blank image; keyboard
  navigation and pointer-down cancel before their actions run.
- Native commit errors/timeouts release the panel and image handles; successful
  handoff focuses the correct pointer window exactly once.

Only after explicit permission approval, run a separate native capture fixture
using disposable test windows: opaque/translucent, occluded, partly/fully
 offscreen, Retina/non-Retina, minimized, closed, another Space, and mixed-size
windows. Measure cold/warm p50/p95 enumeration and capture, first-present delay,
refresh miss rate, texture memory/RSS, and handoff duration. Use memory-only
visual inspection; no pixels saved to validation logs. Compare motion with the
native route and verify permission-denied behavior. Do not claim smoother motion
until the actual desktop test confirms it.
