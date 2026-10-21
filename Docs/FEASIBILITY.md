# Feasibility — current 0.4 implementation

RibbonDesk uses Swift/AppKit/SwiftUI plus a small Objective-C interop target.
Global horizontal scrolling and native inertia move compatible live windows.
Each connected display has an independent logical strip. Launch captures eligible
windows from all ordinary macOS desktops, including the RibbonDesk dashboard,
and gathers each display’s windows onto its active desktop.

Public AX APIs alone cannot transfer another app’s window between Spaces. The
optional private SkyLight boundary is isolated in `Spaces.swift` and `SpaceInterop/`.
Symbols are resolved at runtime, without process injection, privileged helpers,
or SIP changes. On macOS 15.7.3, legacy transfer calls were observed to do nothing;
the asynchronous bridged operation successfully transferred real windows.
Actual Space membership is polled after every transfer. Unsupported/missing APIs
stop the operation with durable originals retained, rather than claiming success.

Some applications withhold inactive-desktop AX windows. The app saves candidate
CG identity, frame, and Space membership before transfer, then binds the exact
AX identity after gathering. It returns unsupported candidates. Minimized/hidden
windows remain unchanged; fullscreen, modal, fixed-size, excluded, and ambiguous
windows are accounted for. Future OS versions can break private API behavior.

Pause cancels/drains movement and restores frames followed by original desktop
membership. Crash recovery validates process identity and window numbers across
all Spaces. Closed windows retire; surviving unavailable windows stay pending.
The recovery file is never overwritten by a new session while pending IDs remain.

Public AX still moves whole windows rather than clipping/compositing a strip.
Parked overflow can overlap with reachable edge handles. Target-app AX latency
and app size constraints remain practical limits. Space/display changes and
permission loss pause control. Broad application compatibility and a guaranteed
frame rate are unproven. The build is locally ad-hoc signed, not notarized.

See [VALIDATION.md](VALIDATION.md) for actual automated/native evidence. The
historical 0.3 behavior and evidence are preserved in [VALIDATION-0.3.md](VALIDATION-0.3.md).
