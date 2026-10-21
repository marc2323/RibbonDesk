import AppKit
import ApplicationServices
import Combine
import RibbonCore

// These events are delivered directly to the production NSView. Nothing is
// posted to the OS, and the fake bridge never enumerates or moves user windows.
final class ScrollEvent: NSEvent {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var fingerPhase: NSEvent.Phase = .changed
    var inertia: NSEvent.Phase = []
    var precise = true
    override var type: NSEvent.EventType { .scrollWheel }
    override var scrollingDeltaX: CGFloat { x }
    override var scrollingDeltaY: CGFloat { y }
    override var phase: NSEvent.Phase { fingerPhase }
    override var momentumPhase: NSEvent.Phase { inertia }
    override var hasPreciseScrollingDeltas: Bool { precise }
    static func make(_ x: CGFloat = 0, _ y: CGFloat = 0, _ phase: NSEvent.Phase = .changed,
                     momentum: NSEvent.Phase = [], precise: Bool = true) -> ScrollEvent {
        let event = ScrollEvent()
        event.x = x; event.y = y; event.fingerPhase = phase
        event.inertia = momentum; event.precise = precise
        return event
    }
}

final class ContactTouch: NSTouch, @unchecked Sendable {
    var identifier: NSString = ""
    var position = CGPoint.zero
    var contactPhase: NSTouch.Phase = .moved
    override var identity: any NSCopying & NSObjectProtocol { identifier }
    override var normalizedPosition: NSPoint { position }
    override var phase: NSTouch.Phase { contactPhase }
}

final class GestureEvent: NSEvent {
    var contacts: Set<NSTouch> = []
    var eventTime = 0.0
    var fingerPhase: NSEvent.Phase = .changed
    override var type: NSEvent.EventType { .gesture }
    override var phase: NSEvent.Phase { fingerPhase }
    override var timestamp: TimeInterval { eventTime }
    override func allTouches() -> Set<NSTouch> { contacts }
    static func make(_ x: Double, count: Int = 3, at time: Double,
                     phase: NSEvent.Phase = .changed, ended: Bool = false) -> GestureEvent {
        let event = GestureEvent(); event.eventTime = time; event.fingerPhase = phase
        event.contacts = Set((0..<count).map { index in
            let touch = ContactTouch()
            // Distinct NSString objects with equal values exercise identity equality.
            touch.identifier = NSString(format: "contact-%d", index)
            touch.position = CGPoint(x: x + Double(index) * 0.03, y: 0.5)
            touch.contactPhase = ended ? .ended : .moved
            return touch
        })
        return event
    }
}

final class FakeShortcuts: ShortcutHandling {
    var onAction: ((DeskAction) -> Void)?
    var registered = false
    func register() throws { registered = true }
    func unregister() { registered = false }
}

@MainActor
final class ManualFrameClock: FrameClockDriving {
    let displayID: String?
    private let tick: () -> Void
    private(set) var running = false
    init(displayID: String?, tick: @escaping () -> Void) { self.displayID = displayID; self.tick = tick }
    func start() { running = true }
    func stop() { running = false }
    func fire() { if running { tick() } }
}

@MainActor
final class FakeScroll: GlobalScrollHandling {
    var onBegin: ((CGPoint) -> Void)?
    var onScroll: ((Double, CGPoint) -> Void)?
    var onFinish: ((CGPoint) -> Void)?
    var onCompletion: ((RibbonSwipeCompletion, CGPoint) -> Void)?
    var onFailure: (() -> Void)?
    var started = false
    var failStart = false
    var settings = RibbonMotionSettings()
    func updateMotionSettings(_ settings: RibbonMotionSettings) { self.settings = settings }
    func emitScroll(_ delta: Double, at point: CGPoint) { onScroll?(delta * settings.speed, point) }
    func start() throws {
        if failStart { throw WindowControlError.message("Tap unavailable") }
        started = true
    }
    func stop() { started = false }
}

/// Uses the actual gesture/coast processor while leaving the native event tap
/// detached. Only in-memory contacts can reach the fake desktop below.
@MainActor
final class ProcessorScroll: GlobalScrollHandling {
    let processor = GlobalScroll()
    var onBegin: ((CGPoint) -> Void)? {
        get { processor.onBegin }
        set { processor.onBegin = newValue }
    }
    var onScroll: ((Double, CGPoint) -> Void)? {
        get { processor.onScroll }
        set { processor.onScroll = newValue }
    }
    var onFinish: ((CGPoint) -> Void)? {
        get { processor.onFinish }
        set { processor.onFinish = newValue }
    }
    var onCompletion: ((RibbonSwipeCompletion, CGPoint) -> Void)? {
        get { processor.onCompletion }
        set { processor.onCompletion = newValue }
    }
    var onFailure: (() -> Void)? {
        get { processor.onFailure }
        set { processor.onFailure = newValue }
    }
    var started = false
    func start() throws { started = true }
    func stop() { started = false; processor.stop() }
    func updateMotionSettings(_ settings: RibbonMotionSettings) { processor.updateMotionSettings(settings) }
    func cancelGesture() { processor.cancelGesture() }
}

@MainActor
final class MemoryStore: SessionPersisting {
    var location: String { "in-memory test snapshot" }
    var snapshot: SessionSnapshot?
    var failSave = false
    func load() throws -> SessionSnapshot? { snapshot }
    func save(_ snapshot: SessionSnapshot) throws {
        if failSave { throw WindowControlError.message("Fixture disk failure") }
        self.snapshot = snapshot
    }
}

@MainActor
final class FakeBridge: WindowBridge {
    var windows: [ManagedWindow] = []
    var frames: [String: Frame] = [:]
    var minimumWidths: [String: Double] = [:]
    func minimumWidth(of window: ManagedWindow) -> Double { minimumWidths[window.id] ?? 240 }
    var writes: [(String, Frame)] = []
    var focused: [String] = []
    var frontmostID: String?
    var topmostID: String?
    var raised: [[String]] = []
    // Front-to-back ordering is independent of geometry and keyboard focus.
    // Native floating levels remain above normal app windows when raised.
    var stackingOrder: [String] = []
    var stackingLevels: [String: Int] = [:]
    var simulatedAppGroups: [String: String] = [:]
    var simulateFrontmostAppRaiseRestriction = false
    var effectiveStackingOrder: [String] {
        stackingOrder.enumerated().sorted { left, right in
            let leftLevel = stackingLevels[left.element, default: 0]
            let rightLevel = stackingLevels[right.element, default: 0]
            return leftLevel == rightLevel ? left.offset < right.offset : leftLevel > rightLevel
        }.map(\.element)
    }
    private func orderFront(_ id: String) {
        stackingOrder.removeAll { $0 == id }; stackingOrder.insert(id, at: 0)
    }
    private func raiseWithoutActivating(_ id: String) {
        guard simulateFrontmostAppRaiseRestriction, let frontmostID,
              let frontGroup = simulatedAppGroups[frontmostID],
              simulatedAppGroups[id] != frontGroup else { orderFront(id); return }
        stackingOrder.removeAll { $0 == id }
        let boundary = stackingOrder.lastIndex { simulatedAppGroups[$0] == frontGroup }
        stackingOrder.insert(id, at: boundary.map { $0 + 1 } ?? 0)
    }
    var positionOrders: [[String]] = []
    var missing: Set<String> = []
    var away: Set<String> = []
    var gatherCount = 0
    var failGather = false
    var failSpaceRestore: Set<String> = []
    var returnedSpaces: [String] = []
    var rejectedDuringGather: Set<String> = []
    var desktopStillMatches = true
    var desktopOverviewActive = false
    var activeDesktops: [String: UInt64]?
    var desktopReads = 0
    var visibleReads = 0
    var availableReads = 0
    func currentDesktops(_ displays: [DisplayInfo]) throws -> [String: UInt64] {
        desktopReads += 1
        return activeDesktops ?? Dictionary(uniqueKeysWithValues: displays.map { ($0.id, 0) })
    }
    var visibilityLagsTransfer = false
    var failNextWrite = false
    var responseDelay: UInt64 = 0
    var positionBatches = 0
    var frameWrites = 0
    var holdMotionBatches = false
    private var motionWaiters: [CheckedContinuation<Void, Never>] = []
    var activeMotionBatches = 0
    var maximumMotionBatches = 0
    var positionTargets: [[String: Frame]] = []
    func releaseMotionBatch() { if !motionWaiters.isEmpty { motionWaiters.removeFirst().resume() } }
    var constrainedMinimumWidths: [String: Double] = [:]
    var constrainedMaximumHeights: [String: Double] = [:]
    // Opt-in native behavior: shrinking a window at its parked origin is
    // refused when the requested rectangle would be outside this display.
    // The real staging executor runs against these stateful native writes.
    var resizeViewport: Frame?
    var stageParkedResizes = true
    var nativeResizeSteps: [(id: String, operation: String, frame: Frame)] = []
    var offscreenResizeRefusals = 0
    var staleProxyIDs: Set<String> = []
    var staleEligibilityIDs: Set<String> = []
    var persistentProxyFailures: Set<String> = []
    var rejectedRefreshIDs: Set<String> = []
    var refreshOverrides: [String: ManagedWindow] = [:]
    var refreshCalls: [String] = []
    var holdRefresh = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    func releaseRefresh() { if !refreshWaiters.isEmpty { refreshWaiters.removeFirst().resume() } }
    var refreshedElements: [String: AXUIElement] = [:]
    var proxyFailures = 0
    var discoveries = 0
    var lastExclusions: Set<String> = []
    var beforeWrite: (() -> Void)?
    init() {
        for index in 0..<4 {
            let frame = Frame(x: Double(index * 100 + 40), y: 60, width: 700, height: 500)
            let item = ManagedWindow(id: "w\(index)", number: UInt32(index + 1), pid: getpid(),
                                     element: AXUIElementCreateApplication(pid_t(100000 + index)),
                                     original: frame, title: "Fixture \(index)", appName: "Fixture")
            windows.append(item); frames[item.id] = frame
            stackingOrder.append(item.id)
        }
    }
    func isTrusted() -> Bool { true }
    func desktopsMatch(_ windows: [ManagedWindow], displays: [DisplayInfo]) -> Bool { desktopStillMatches }
    func visibleWindows() -> [VisibleWindow] {
        visibleReads += 1
        return availableWindows().filter { cg in !windows.contains { $0.number == cg.number && away.contains($0.id) } }
    }
    func availableWindows() -> [VisibleWindow] {
        availableReads += 1
        return windows.filter { !missing.contains($0.id) }.map {
            VisibleWindow(number: $0.number, pid: $0.pid, frame: frames[$0.id]!)
        }
    }
    func discover(in viewport: Frame, excluding bundleIDs: Set<String>) throws -> [ManagedWindow] {
        discoveries += 1; lastExclusions = bundleIDs
        return windows.filter { !away.contains($0.id) && !missing.contains($0.id) }
    }
    func gather(_ windows: [ManagedWindow]) async throws -> [ManagedWindow] {
        gatherCount += 1; beforeWrite?()
        if let first = windows.first { away.remove(first.id) }
        if failGather { throw WindowControlError.message("Fixture desktop transfer refused") }
        if visibilityLagsTransfer {
            Task { try? await Task.sleep(nanoseconds: 120_000_000); self.away.removeAll() }
        } else { away.removeAll() }
        returnedSpaces += windows.filter { rejectedDuringGather.contains($0.id) }.map(\.id)
        return windows.filter { !rejectedDuringGather.contains($0.id) }
    }
    func restoreSpace(_ window: ManagedWindow) async throws {
        if failSpaceRestore.contains(window.id) { throw WindowControlError.message("Fixture original desktop unavailable") }
        returnedSpaces.append(window.id)
    }
    func eligible(_ window: AXUIElement) -> Bool { true }
    func eligible(_ window: ManagedWindow) -> Bool {
        !staleEligibilityIDs.contains(window.id) || refreshedElements[window.id].map { CFEqual($0, window.element) } == true
    }
    func refreshWindow(_ window: ManagedWindow, saved: SavedWindow, capturedAt: Date) async throws -> ManagedWindow? {
        refreshCalls.append(window.id)
        if holdRefresh { await withCheckedContinuation { refreshWaiters.append($0) } }
        try Task.checkCancellation()
        guard !rejectedRefreshIDs.contains(window.id), !away.contains(window.id), !missing.contains(window.id) else { return nil }
        if let override = refreshOverrides[window.id] { return override }
        let element = AXUIElementCreateApplication(pid_t(200000 + Int(window.number)))
        refreshedElements[window.id] = element
        return ManagedWindow(id: window.id, number: window.number, pid: window.pid, element: element,
            original: window.original, title: window.title, appName: window.appName, originalSpaces: window.originalSpaces,
            destinationSpace: window.destinationSpace, isLocal: window.isLocal, requiresResolution: false,
            stagedFromOtherDesktop: window.stagedFromOtherDesktop, preservesDesktop: window.preservesDesktop)
    }
    func frame(of window: AXUIElement) -> Frame? {
        windows.first(where: { CFEqual($0.element, window) }).flatMap { frames[$0.id] }
    }
    func setFrame(_ target: Frame, of window: ManagedWindow) async throws {
        try Task.checkCancellation()
        if persistentProxyFailures.contains(window.id) || (staleProxyIDs.contains(window.id) &&
            refreshedElements[window.id].map { CFEqual($0, window.element) } != true) {
            proxyFailures += 1
            throw WindowElementFailure(windowID: window.id, appName: window.appName, reason: .invalidElement)
        }
        frameWrites += 1; beforeWrite?()
        if failNextWrite {
            failNextWrite = false
            throw WindowControlError.message("Fixture rejected a write.")
        }
        var accepted = target
        if let viewport = resizeViewport {
            func moveNative(_ requested: Frame) async throws {
                try Task.checkCancellation()
                var actual = frames[window.id]!
                actual.x = requested.x; actual.y = requested.y
                frames[window.id] = actual
                nativeResizeSteps.append((window.id, "move", actual))
            }
            func resizeNative(_ requested: Frame) async throws {
                try Task.checkCancellation()
                var actual = frames[window.id]!
                guard abs(actual.width - requested.width) > 1 || abs(actual.height - requested.height) > 1 else { return }
                let rectangle = Frame(x: actual.x, y: actual.y, width: requested.width, height: requested.height)
                if rectangle.x >= viewport.x && rectangle.maxX <= viewport.maxX &&
                    rectangle.y >= viewport.y && rectangle.maxY <= viewport.maxY {
                    actual.width = requested.width; actual.height = requested.height
                    if target != window.original {
                        if let minimum = constrainedMinimumWidths[window.id] { actual.width = max(actual.width, minimum) }
                        if let maximum = constrainedMaximumHeights[window.id] { actual.height = min(actual.height, maximum) }
                    }
                } else { offscreenResizeRefusals += 1 }
                frames[window.id] = actual
                nativeResizeSteps.append((window.id, "resize", actual))
                if abs(actual.width - requested.width) > 6 || abs(actual.height - requested.height) > 6 {
                    throw WindowFrameConstraint(windowID: window.id, actual: actual, target: target)
                }
            }
            if stageParkedResizes {
                _ = try await WindowResizeStaging.prepare(current: frames[window.id]!, target: target,
                    viewport: viewport, moveTo: moveNative, resizeTo: resizeNative)
            }
            try await moveNative(target)
            try await resizeNative(target)
            accepted = frames[window.id]!
        } else if target != window.original {
            if let minimum = constrainedMinimumWidths[window.id] { accepted.width = max(accepted.width, minimum) }
            if let maximum = constrainedMaximumHeights[window.id] { accepted.height = min(accepted.height, maximum) }
        }
        writes.append((window.id, accepted)); frames[window.id] = accepted
        if accepted != target {
            throw WindowFrameConstraint(windowID: window.id, actual: accepted, target: target)
        }
        if responseDelay > 0 {
            let before = window.original
            frames[window.id] = Frame(x: (before.x + target.x) / 2, y: (before.y + target.y) / 2,
                                      width: (before.width + target.width) / 2, height: (before.height + target.height) / 2)
            try await Task.sleep(nanoseconds: responseDelay)
            try Task.checkCancellation()
            frames[window.id] = target
        }
    }
    func movePositions(_ targets: [(ManagedWindow, Frame)]) async throws {
        try Task.checkCancellation()
        if failNextWrite { failNextWrite = false; throw WindowControlError.message("Fixture rejected a pan") }
        positionBatches += 1; beforeWrite?()
        activeMotionBatches += 1
        maximumMotionBatches = max(maximumMotionBatches, activeMotionBatches)
        defer { activeMotionBatches -= 1 }
        positionOrders.append(targets.map { $0.0.id })
        positionTargets.append(Dictionary(uniqueKeysWithValues: targets.map { ($0.0.id, $0.1) }))
        if holdMotionBatches { await withCheckedContinuation { motionWaiters.append($0) } }
        if responseDelay > 0 { try await Task.sleep(nanoseconds: responseDelay) }
        try Task.checkCancellation()
        for (window, target) in targets {
            var moved = frames[window.id]!
            moved.x = target.x; moved.y = target.y
            writes.append((window.id, moved)); frames[window.id] = moved
        }
    }
    func recover(_ saved: [SavedWindow], capturedAt: Date) -> [ManagedWindow] {
        windows.filter { w in saved.contains { $0.id == w.id } && !missing.contains(w.id) }
    }
    func focusedWindowIdentity() -> (pid: pid_t, number: CGWindowID)? {
        guard let window = windows.first(where: { $0.id == frontmostID }) else { return nil }
        return (window.pid, window.number)
    }
    func topWindowIdentity(at point: CGPoint) -> (pid: pid_t, number: CGWindowID)? {
        guard let window = windows.first(where: { $0.id == topmostID }) else { return nil }
        return (window.pid, window.number)
    }
    func raiseVisibleWindows(_ windows: [ManagedWindow]) async throws {
        try Task.checkCancellation()
        if !windows.isEmpty {
            raised.append(windows.map(\.id))
            for window in windows { raiseWithoutActivating(window.id) }
        }
    }
    func focus(_ window: ManagedWindow) throws {
        focused.append(window.id); frontmostID = window.id; orderFront(window.id)
    }
    var restored: Bool { windows.allSatisfy { frames[$0.id] == $0.original } }
}

@main
@MainActor
struct DesktopChecks {
    static var assertions = 0
    static var failures = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String, line: UInt = #line) {
        assertions += 1
        if !condition() { failures += 1; print("FAIL line \(line): \(label)") }
    }
    static func drain() async { try? await Task.sleep(nanoseconds: 60_000_000) }
    static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        expect(condition(), "Timed out awaiting fixture response")
    }

    static func checkEvents() {
        let view = TrackpadScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 56))
        var deltas: [Double] = []
        var finishes = 0
        view.onScroll = { deltas.append($0) }; view.onFinish = { finishes += 1 }
        for enabled in [false, true] {
            view.inputEnabled = enabled
            view.localGestureEnabled = enabled
            for event in [ScrollEvent.make(-30, 0, .began), ScrollEvent.make(-40, 0),
                          ScrollEvent.make(0, 0, .ended),
                          ScrollEvent.make(-100, 0, [], momentum: .changed),
                          ScrollEvent.make(0, 20, .began), ScrollEvent.make(1, 0, [], precise: false)] {
                view.scrollWheel(with: event)
            }
        }
        expect(deltas.isEmpty && finishes == 0, "Local surfaces never turn two-finger/wheel input into ribbon movement")
        print("PASS Local two-finger defaults")
    }

    static func checkDemo() async {
        let desk = DeskController(preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        desk.scrollSpeed = 1
        desk.startDemo()
        let widths = desk.state.items.map(\.width)
        let focused = desk.state.focusedID
        desk.scrollHorizontally(by: 500)
        expect(desk.state.scrollOffset == 500 && desk.state.focusedID == focused, "Demo pans without revealing old focus")
        expect(desk.state.items.map(\.width) == widths, "Panning preserves widths")
        desk.finishHorizontalScroll()
        expect(desk.state.focusedID == focused, "Finger lift leaves focus unchanged during settling")
        await waitUntil { !desk.isSettling }
        expect(desk.state.focusedID == "build", "Demo settling chooses its nearest visible column")
        desk.pauseAndRestore()
        let state = desk.state
        desk.scrollHorizontally(by: 300); desk.finishHorizontalScroll()
        expect(desk.state == state && desk.mode == .paused, "Paused controller ignores delayed input")
        print("PASS Demo controller")
    }

    static func checkLiveController() async throws {
        guard let screen = NSScreen.screens.first else {
            failures += 1; print("FAIL controller checks require a display"); return
        }
        let bridge = FakeBridge(), keys = FakeShortcuts(), input = FakeScroll()
        let desk = DeskController(bridge: bridge, shortcuts: keys, screens: { [screen] }, scrollInput: input, store: MemoryStore(), preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        desk.scrollSpeed = 1
        try desk.beginLiveSession(bridge.windows, on: screen)
        await drain()
        expect(desk.mode == .live && keys.registered, "Live pipeline starts")
        let writesBeforeMove = bridge.writes.count
        bridge.frames[bridge.windows[0].id]?.x += 90
        desk.checkSession()
        expect(desk.mode == .live && bridge.writes.count == writesBeforeMove,
               "An ordinary window move does not disable scrolling or cause polling writes")
        desk.showLiveScrollBar()
        guard let panel = NSApp.windows.first(where: { $0.title == "RibbonDesk Live Scroll Strip" && $0.isVisible }),
              let surface = panel.contentView as? TrackpadScrollView else {
            failures += 1; print("FAIL live scroll panel missing"); desk.pauseAndRestore(); return
        }
        expect(!panel.canBecomeKey && !panel.canBecomeMain, "Live surface does not steal keyboard focus")
        let focusCount = bridge.focused.count
        surface.scrollWheel(with: ScrollEvent.make(-100, 0, .began))
        expect(desk.state.scrollOffset == 0, "Live panel preserves two-finger default behavior")
        input.onBegin?(.zero)
        input.onScroll?(10, .zero)
        for _ in 0..<40 { input.onScroll?(5, .zero) }
        await drain()
        expect(desk.state.scrollOffset == 210, "All pan intent accumulates before queued AX commit")
        expect(bridge.focused.count == focusCount, "Panning does not activate captured apps")
        await waitUntil { desk.placements.allSatisfy { bridge.frames[$0.id] == $0.frame } }
        expect(desk.placements.allSatisfy { bridge.frames[$0.id] == $0.frame }, "Latest queued pan reaches every enrolled window")
        input.onFinish?(.zero)
        await waitUntil { !desk.isSettling }
        expect(bridge.focused.count == focusCount + 1 && bridge.focused.last == desk.state.focusedID, "Finger lift focuses once after layout")
        let afterLift = desk.state
        surface.scrollWheel(with: ScrollEvent.make(-400, 0, [], momentum: .changed))
        await drain()
        expect(desk.state == afterLift, "Momentum does not move live layout")
        input.onBegin?(.zero); input.onScroll?(500, .zero)
        desk.pauseAndRestore() // Pause before the pending layout gets a main-queue turn.
        await drain()
        expect(bridge.restored && desk.pendingRestoreCount == 0 && !keys.registered, "Pause restores captured originals and unregisters shortcuts")
        let restoredCount = bridge.writes.count
        await drain()
        expect(bridge.writes.count == restoredCount && !panel.isVisible, "Cancelled queued layouts never overwrite restoration")
        surface.scrollWheel(with: ScrollEvent.make(-200, 0, .ended))
        await drain()
        expect(bridge.writes.count == restoredCount, "Hidden surface cannot resume a paused live session")

        try desk.beginLiveSession(bridge.windows, on: screen)
        await drain()
        bridge.failNextWrite = true
        desk.scrollHorizontally(by: 100)
        await drain()
        expect(desk.mode == .paused && bridge.restored && desk.pendingRestoreCount == 0, "AX failure stops pan and restores originals")
        expect(!keys.registered, "Failure removes shortcuts")
        print("PASS Live controller queue, focus, cancellation, restoration, and AX failure (fake bridge)")
    }

    static func checkDelayedCancellation() async throws {
        guard let screen = NSScreen.screens.first else { return }
        let bridge = FakeBridge(), keys = FakeShortcuts()
        bridge.responseDelay = 80_000_000
        let desk = DeskController(bridge: bridge, shortcuts: keys, screens: { [screen] }, scrollInput: FakeScroll(), store: MemoryStore(), preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        desk.scrollSpeed = 1
        try desk.beginLiveSession(bridge.windows, on: screen)
        await waitUntil { desk.placements.allSatisfy { bridge.frames[$0.id] == $0.frame } }
        await drain()
        expect(desk.mode == .live, "Delayed target responses do not stop the controller")
        desk.scrollHorizontally(by: 200)
        try? await Task.sleep(nanoseconds: 10_000_000)
        desk.scrollHorizontally(by: 100)
        await waitUntil {
            desk.placements.first?.frame.x == desk.viewport.x + desk.state.edgeInset - 300 &&
                desk.placements.allSatisfy { bridge.frames[$0.id] == $0.frame }
        }
        expect(desk.state.scrollOffset == 300, "New intent supersedes in-flight delayed writes")
        desk.scrollHorizontally(by: 100)
        try? await Task.sleep(nanoseconds: 10_000_000)
        desk.pauseAndRestore()
        expect(!desk.prepareToQuit(), "Quit waits for asynchronous restoration")
        await waitUntil { desk.pendingRestoreCount == 0 }
        let count = bridge.writes.count
        await drain()
        expect(bridge.restored && !keys.registered, "Pause restores windows after cancelling in-flight responses")
        expect(bridge.writes.count == count && desk.prepareToQuit(), "No obsolete continuation writes after restoration")
        print("PASS Delayed AX responses, latest intent, in-flight cancellation, and quit")
    }

    static func checkFrameConvergence() async throws {
        let old = Frame(x: 24, y: 242, width: 894, height: 528)
        let target = Frame(x: 16, y: 41, width: 894, height: 763)
        let start = ProcessInfo.processInfo.systemUptime
        let settled = try await FrameConvergence.wait(appName: "Fixture", matches: { $0 == target }) {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            // An immediate target echo, followed by an older animation, then
            // real convergence. Returning on that first sample would be wrong.
            return (target, elapsed < 0.01 || elapsed > 0.14 ? target : old)
        }
        expect(settled == target && ProcessInfo.processInfo.systemUptime - start >= 0.17,
               "Target echo and an older animation cannot cause premature success")
        let deadline = try await FrameConvergence.wait(appName: "Fixture", returnAtDeadline: true,
                                                       matches: { $0 == target }) { (target, old) }
        expect(deadline == old, "Correction receives actual geometry at its deadline")
        let task = Task {
            try await FrameConvergence.wait(appName: "Fixture", matches: { $0 == target }) { (target, old) }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; expect(false, "Cancelled verification must throw") }
        catch is CancellationError { expect(true, "Cancellation interrupts verification") }
        catch { expect(false, "Unexpected verification error") }
        print("PASS Actual convergence helper: target echo, late animation, deadline, cancellation")
    }

    static func contacts(_ x: Double, _ y: Double = 0.5, count: Int = 3, shift: Int = 0) -> [ThreeFingerSwipe.Contact] {
        (0..<count).map { .init(id: $0 + shift, x: x + Double($0) * 0.03, y: y) }
    }

    static func checkThreeFingerMath() {
        var swipe = ThreeFingerSwipe()
        _ = swipe.consume(contacts(0.5), at: 1)
        var total = 0.0
        for i in 1...20 { total += swipe.consume(contacts(0.5 - Double(i) * 0.0002), at: 1 + Double(i) * 0.01).delta }
        expect(abs(total - 9.6) < 0.0001, "Tiny three-finger motion accumulates without losing travel")
        let reversed = swipe.consume(Array(contacts(0.499).reversed()), at: 1.21)
        expect(reversed.delta < 0, "Quick reversal and contact ordering preserve direction")
        let lift = swipe.consume([], at: 1.22, phase: .ended)
        expect(lift.finished && lift.velocity < 0, "Flick momentum follows the latest direction")
        _ = swipe.consume(contacts(0.5), at: 2)
        _ = swipe.consume(contacts(0.48), at: 2.02)
        expect(swipe.consume(contacts(0.1, shift: 10), at: 2.03).delta == 0,
               "Finger replacement never creates a centroid jump")
        _ = swipe.consume(contacts(0.08, shift: 10), at: 2.04)
        expect(swipe.consume([], at: 2.3, phase: .ended).velocity == 0, "Holding before lift suppresses stale momentum")
        _ = swipe.consume(contacts(0.5), at: 3)
        expect(swipe.consume(contacts(0.5, 0.53), at: 3.02).delta == 0, "Vertical three-finger gestures remain available")
        expect(swipe.consume(contacts(0.4, 0.53), at: 3.03).delta == 0, "Vertical axis cannot wobble into a ribbon swipe")
        _ = swipe.consume([], at: 3.04, phase: .ended)
        for count in [1, 2, 4, 5] {
            _ = swipe.consume(contacts(0.5, count: count), at: 4)
            expect(swipe.consume(contacts(0.4, count: count), at: 4.02).delta == 0,
                   "Only exactly three contacts navigate the ribbon (count \(count))")
        }
        _ = swipe.consume(contacts(0.5), at: 5)
        _ = swipe.consume([], at: 5.01)
        expect(swipe.consume(contacts(0.48), at: 5.02).began, "Empty interleaved events do not discard contact anchors")
        expect(swipe.consume([], at: 5.03, phase: .cancelled).velocity == 0, "Cancelled swipes never coast")
        _ = swipe.consume(contacts(0.5), at: 6)
        expect(swipe.consume(contacts(.nan), at: 6.02).delta == 0, "Invalid contacts are rejected without window motion")
        func distance(_ rate: Double) -> Double {
            var momentum = SwipeMomentum(velocity: 1500), distance = 0.0
            for _ in 0..<200 where !momentum.finished { distance += momentum.step(seconds: 1 / rate) }
            expect(momentum.finished, "Coasting terminates at \(rate) Hz")
            return distance
        }
        expect(abs(distance(60) - distance(120)) < 0.5, "Momentum distance does not depend on frame rate")
        var huge = SwipeMomentum(velocity: .infinity)
        expect(huge.finished && huge.step(seconds: 1) == 0, "Invalid velocity cannot start runaway inertia")
        huge = SwipeMomentum(velocity: 1_000_000)
        expect(huge.step(seconds: 10) < 400, "A stalled frame has bounded momentum travel")
        print("PASS Three-finger contact math and inertia")
    }

    static func checkGlobalRouting() async {
        checkThreeFingerMath()
        let input = GlobalScroll(), point = CGPoint(x: 100, y: 150)
        input.updateMotionSettings(.linear)
        var deltas: [Double] = [], finishes = 0, begins = 0, points: [CGPoint] = []
        input.onBegin = { _ in begins += 1 }
        input.onScroll = { delta, at in deltas.append(delta); points.append(at) }
        input.onFinish = { _ in finishes += 1 }
        for event in [ScrollEvent.make(-20, 0, .began), ScrollEvent.make(20, 0),
                      ScrollEvent.make(-100, 0, [], momentum: .changed), ScrollEvent.make(0, 12)] {
            expect(!input.route(event, at: point), "Two-finger/wheel events always pass through unchanged")
        }
        _ = input.route(GestureEvent.make(0.5, count: 2, at: 1), at: point)
        _ = input.route(GestureEvent.make(0.4, count: 2, at: 1.02), at: point)
        await drain()
        expect(deltas.isEmpty && begins == 0, "Two contacts cannot begin ribbon control")
        _ = input.route(GestureEvent.make(0.5, at: 2), at: point)
        expect(input.route(GestureEvent.make(0.48, at: 2.02), at: point), "Three-finger horizontal movement claims the gesture")
        _ = input.route(GestureEvent.make(0.495, at: 2.03), at: CGPoint(x: 900, y: 200))
        _ = input.route(GestureEvent.make(0.495, count: 0, at: 2.04, phase: .cancelled), at: point)
        await drain()
        expect(deltas.count == 2 && abs(deltas[0] - 48) < 0.001 && abs(deltas[1] + 36) < 0.001,
               "Three-finger movement and fast reversal deliver signed travel")
        expect(begins == 1 && finishes == 1 && points.allSatisfy { $0 == point }, "One gesture retains its starting display and finishes once")
        _ = input.route(contacts: contacts(0.5), at: point, time: 3)
        _ = input.route(contacts: contacts(0.48), at: point, time: 3.02)
        _ = input.route(GestureEvent.make(0.48, at: 3.03, ended: true), at: point)
        await drain()
        expect(deltas.count > 3 && finishes == 1, "Three-finger flick continues with decaying inertia before focusing")
        _ = input.route(contacts: contacts(0.5, count: 2), at: point, time: 3.1)
        await drain()
        let interrupted = deltas.count
        await drain()
        expect(finishes == 2 && deltas.count == interrupted, "A new two-finger gesture immediately stops ribbon momentum")
        _ = input.route(contacts: contacts(0.5), at: point, time: 4)
        _ = input.route(contacts: contacts(0.49), at: point, time: 4.02)
        _ = input.route(contacts: [], at: point, time: 4.03, phase: .ended)
        try? await Task.sleep(nanoseconds: 1_700_000_000)
        expect(finishes == 3, "Inertia settles exactly once without another hardware event")
        _ = input.route(GestureEvent.make(0.5, at: 4.5), at: point)
        _ = input.route(GestureEvent.make(0.48, at: 4.52), at: point)
        let partial = GestureEvent.make(0.48, at: 4.53)
        (partial.contacts.first { ($0 as! ContactTouch).identifier == "contact-2" } as! ContactTouch).contactPhase = .ended
        _ = input.route(partial, at: point)
        // Real releases retain sliding contacts for a few samples. This drift
        // exceeded the old threshold and cancelled inertia in the native trace.
        _ = input.route(GestureEvent.make(0.474, count: 2, at: 4.538), at: point)
        let one = GestureEvent.make(0.47, count: 2, at: 4.546)
        (one.contacts.first { ($0 as! ContactTouch).identifier == "contact-1" } as! ContactTouch).contactPhase = .ended
        _ = input.route(one, at: point)
        let remaining = GestureEvent.make(0.465, count: 1, at: 4.554, ended: true)
        _ = input.route(remaining, at: point)
        let beforeCoast = deltas.count
        await drain()
        expect(deltas.count > beforeCoast + 1 && finishes == 3, "Sliding staggered 3-to-2-to-1-to-zero release preserves flick momentum")
        _ = input.route(GestureEvent.make(0.5, count: 2, at: 4.6, phase: .began), at: point)
        await drain()
        expect(finishes == 4, "A fresh two-finger touch interrupts staggered-release inertia")
        let beforeStop = deltas.count
        _ = input.route(contacts: contacts(0.5), at: point, time: 5)
        _ = input.route(contacts: contacts(0.48), at: point, time: 5.02)
        input.stop()
        await drain()
        expect(deltas.count == beforeStop, "Stop invalidates callbacks already queued by the tap")
        _ = input.route(contacts: contacts(0.5), at: point, time: 6)
        _ = input.route(contacts: contacts(0.48), at: point, time: 6.02)
        try? await Task.sleep(nanoseconds: 140_000_000)
        expect(deltas.count > beforeStop + 1, "Missing native end events infer lift and start actual inertia")
        try? await Task.sleep(nanoseconds: 1_650_000_000)
        expect(finishes == 5, "A missing finger-end event has bounded settling")
        input.stop()
        let configured = GlobalScroll()
        configured.updateMotionSettings(.linear)
        var ordered: [String] = [], configuredDeltas: [Double] = [], configuredFinishes = 0
        configured.onBegin = { _ in ordered.append("begin") }
        configured.onScroll = { delta, _ in ordered.append("delta"); configuredDeltas.append(delta) }
        configured.onFinish = { _ in ordered.append("finish"); configuredFinishes += 1 }
        _ = configured.route(contacts: contacts(0.5), at: point, time: 8)
        _ = configured.route(contacts: contacts(0.48), at: point, time: 8.02)
        configured.updateMotionSettings(.init(speed: 2, acceleration: 0, momentum: 0))
        await drain()
        expect(ordered == ["begin", "delta", "finish"] && abs(configuredDeltas[0] - 48) < 0.001,
               "A settings change preserves queued input order and finishes the previous gesture once")
        _ = configured.route(contacts: contacts(0.5), at: point, time: 9)
        _ = configured.route(contacts: contacts(0.48), at: point, time: 9.02)
        _ = configured.route(contacts: [], at: point, time: 9.03, phase: .ended)
        await drain()
        let configuredCount = configuredDeltas.count
        await drain()
        expect(configuredDeltas.count == 2 && abs(configuredDeltas[1] - 96) < 0.001 &&
               configuredFinishes == 2 && configuredDeltas.count == configuredCount,
               "Speed is applied exactly once, and zero momentum finishes without later native deltas")
        configured.stop()
        let local = TrackpadScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 56))
        local.inputEnabled = true; local.localGestureEnabled = true
        local.motionSettings = .init(speed: 2, acceleration: 0, momentum: 0)
        var localDeltas: [Double] = [], localFinishes = 0
        local.onScroll = { localDeltas.append($0) }; local.onFinish = { localFinishes += 1 }
        local.touchesBegan(with: GestureEvent.make(0.5, at: 10))
        local.touchesMoved(with: GestureEvent.make(0.48, at: 10.02))
        local.touchesEnded(with: GestureEvent.make(0.48, count: 0, at: 10.03, phase: .ended))
        await drain()
        expect(localDeltas.count == 1 && abs(localDeltas[0] - configuredDeltas[1]) < 0.001 && localFinishes == 1,
               "Local demo and global input use the same tuned contact math and finish semantics")
        local.motionSettings = .init(speed: 1, acceleration: 0, momentum: 0.35)
        local.touchesBegan(with: GestureEvent.make(0.5, at: 12))
        local.touchesMoved(with: GestureEvent.make(0.46, at: 12.02))
        local.touchesEnded(with: GestureEvent.make(0.46, count: 0, at: 12.03, phase: .ended))
        await drain()
        let localCount = localDeltas.count, localFinishCount = localFinishes
        local.inputCancellationRevision &+= 1
        try? await Task.sleep(nanoseconds: 650_000_000)
        expect(localDeltas.count == localCount && localFinishes == localFinishCount,
               "An explicit demo input revision stops local coast without a stale finish or later deltas")
        local.touchesBegan(with: GestureEvent.make(0.5, at: 13))
        local.touchesMoved(with: GestureEvent.make(0.46, at: 13.02))
        local.inputCancellationRevision &+= 1
        await drain()
        expect(localDeltas.count == localCount && localFinishes == localFinishCount,
               "A demo input revision invalidates local gesture callbacks still queued for delivery")
        local.inputEnabled = false
        print("PASS Three-finger routing, two-finger defaults, reversal, interruption, settings, and settling")
    }

    static func checkDisplaysAndSnapshots() async throws {
        let a = DisplayInfo(id: "main", name: "Built-in", frame: Frame(x: 0, y: 0, width: 1440, height: 900),
                            usable: Frame(x: 0, y: 25, width: 1440, height: 875))
        let b = DisplayInfo(id: "external", name: "External", frame: Frame(x: -1920, y: -240, width: 1920, height: 1080),
                            usable: Frame(x: -1920, y: -215, width: 1920, height: 1055))
        var connected = [a, b]
        let bridge = FakeBridge(), keys = FakeShortcuts(), input = FakeScroll(), store = MemoryStore()
        for index in 4..<22 {
            let frame = Frame(x: -1800 + Double(index * 8), y: -100, width: 650, height: 500)
            let w = ManagedWindow(id: "w\(index)", number: UInt32(index+1), pid: getpid(),
                                  element: AXUIElementCreateApplication(pid_t(100000+index)), original: frame,
                                  title: "External fixture \(index)", appName: "Fixture")
            bridge.windows.append(w); bridge.frames[w.id] = frame
        }
        var savedBeforeWrite = true
        bridge.beforeWrite = { savedBeforeWrite = savedBeforeWrite && store.snapshot?.windows.count == 22 }
        let desk = DeskController(bridge: bridge, shortcuts: keys, displayProvider: { connected }, scrollInput: input, store: store, preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        desk.scrollSpeed = 1
        try desk.beginLiveSession(bridge.windows, using: connected)
        await drain()
        expect(desk.mode == .live && desk.managedWindowCount == 22, "All 22 eligible windows enrolled across two displays; no 12-window cap")
        expect(savedBeforeWrite && store.snapshot?.pending.count == 22, "Durable originals exist before every initial write")
        expect(input.started && keys.registered, "Global input starts only with the live session")
        var fullWidth = StripState(items: [StripItem(id: "full", title: "Full", appName: "Fixture", width: 1855)], edgeInset: 0)
        let fullPlacement = fullWidth.layout(in: Frame(x: 0, y: 25, width: 1856, height: 1055))
        expect(fullPlacement.first?.frame == Frame(x: 0, y: 25, width: 1855, height: 1055),
               "An already maximized window does not get forced into a smaller inset frame")
        expect(bridge.windows.allSatisfy { window in
            guard let display = DisplayInfo.owner(of: window.original, among: connected), let frame = bridge.frames[window.id] else { return false }
            return frame.y == display.usable.y && frame.height == display.usable.height &&
                frame.width == StripState.halfScreenWidth(in: display.usable)
        }, "Launch uses half-screen columns at full usable height on each display")
        let settlingWrites = bridge.frameWrites
        let sampleStart = ProcessInfo.processInfo.systemUptime
        let batchesBefore = bridge.positionBatches
        let motionWritesBefore = bridge.writes.count
        for _ in 0..<500 { input.onScroll?(2, CGPoint(x: -900, y: 200)) }
        await drain()
        expect(desk.activeDisplayID == b.id && desk.state.scrollOffset == 1000, "Pointer routes accumulated input to the external display")
        expect(bridge.frameWrites == settlingWrites && bridge.positionBatches > 0, "Finger movement uses position batches without convergence or resize writes")
        expect(bridge.writes.dropFirst(motionWritesBefore).allSatisfy { id, _ in
            bridge.windows.first(where: { $0.id == id }).flatMap { DisplayInfo.owner(of: $0.original, among: connected) }?.id == b.id
        }, "Sustained motion writes only the active display's ribbon")
        let elapsed = ProcessInfo.processInfo.systemUptime - sampleStart
        expect(bridge.positionBatches - batchesBefore <= Int(ceil(elapsed * 240)) + 1 && bridge.positionBatches - batchesBefore < 100,
               "Hundreds of input samples coalesce into display-rate updates, including high-refresh screens")
        input.onFinish?(CGPoint(x: -900, y: 200)); await waitUntil { !desk.isSettling }
        let externalSnap = desk.state.scrollOffset
        desk.selectDisplay(a.id)
        expect(desk.state.scrollOffset == 0, "External scrolling leaves the built-in strip offset unchanged")
        input.onScroll?(140, CGPoint(x: 600, y: 300)); await drain()
        input.onFinish?(CGPoint(x: 600, y: 300)); await waitUntil { !desk.isSettling }
        desk.selectDisplay(b.id)
        expect(desk.state.scrollOffset == externalSnap, "Each display retains independent scroll state after a gesture ends")
        let focusCount = bridge.focused.count
        input.onScroll?(-20, CGPoint(x: -900, y: 200))
        input.onFinish?(CGPoint(x: -900, y: 200))
        let resumeOrigin = desk.state.scrollOffset
        input.onScroll?(10, CGPoint(x: -900, y: 200))
        await drain()
        expect(desk.state.scrollOffset == resumeOrigin + 10 && bridge.focused.count == focusCount,
               "A new gesture invalidates the previous lift's queued settling and focus")
        input.onFinish?(CGPoint(x: -900, y: 200)); await waitUntil { !desk.isSettling }
        let speedOrigin = desk.state.scrollOffset
        desk.scrollSpeed = 2
        input.emitScroll(10, at: CGPoint(x: -900, y: 200)); await drain()
        expect(desk.state.scrollOffset == speedOrigin + 20, "Scroll speed control scales native input without altering stored widths")
        desk.scrollSpeed = 1
        input.onFinish?(CGPoint(x: -900, y: 200)); await waitUntil { !desk.isSettling }
        expect(bridge.windows.allSatisfy { w in
            let display = DisplayInfo.owner(of: w.original, among: connected)!
            let frame = bridge.frames[w.id]!
            return !connected.contains { $0.id != display.id && $0.frame.intersectionArea(frame) > 0 }
        }, "Edge parking cannot cover an adjacent display, including negative display coordinates")
        connected = [a]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        expect(desk.mode == .paused && !input.started && !keys.registered, "Display removal disables scroll input and shortcuts")
        let writes = bridge.writes.count
        desk.confirmRestore(); await drain()
        expect(bridge.writes.count == writes && store.snapshot?.pending.count == 22, "Changed topology preserves the snapshot without misplaced restore writes")
        connected = [a, b]
        desk.confirmRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        expect(bridge.restored && store.snapshot?.pending.isEmpty == true, "Both displays restore their original geometry and clear pending recovery")
        let below = DisplayInfo(id: "below", name: "Below", frame: Frame(x: 400, y: 900, width: 1440, height: 900),
                                usable: Frame(x: 400, y: 900, width: 1440, height: 900))
        let verticalBridge = FakeBridge(), verticalInput = FakeScroll()
        let vertical = DeskController(bridge: verticalBridge, shortcuts: FakeShortcuts(), displayProvider: { [a, below] },
                                      scrollInput: verticalInput, store: MemoryStore(), preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        vertical.scrollSpeed = 1
        vertical.launch(); await drain()
        verticalInput.onScroll?(100, CGPoint(x: 600, y: 300)); await drain()
        await waitUntil { abs((vertical.placements.first?.frame.x ?? 0) + 100) < 0.11 }
        expect(abs((vertical.placements.first?.frame.x ?? 0) + 100) < 0.11,
               "Vertically arranged displays do not introduce a dead zone at an unoccupied horizontal edge")
        vertical.pauseAndRestore(); await waitUntil { vertical.pendingRestoreCount == 0 }
        print("PASS Two displays, 22 windows, fast scrolling, snapshot-before-write, and topology changes")
    }

    static func checkPersistenceAndStartup() async throws {
        let capture = Date()
        expect(ProcessIdentity.startTime(getpid()).map { $0 <= capture } == true,
               "The public kernel process-start query works for the runner")
        expect(ProcessIdentity.matches(savedLaunch: nil, currentLaunch: nil,
                                       kernelStart: capture.addingTimeInterval(-10), capturedAt: capture),
               "Missing AppKit launch dates can use a process that predates capture")
        expect(!ProcessIdentity.matches(savedLaunch: nil, currentLaunch: nil,
                                        kernelStart: capture.addingTimeInterval(10), capturedAt: capture),
               "A reused PID born after capture is rejected even without an AppKit launch date")
        expect(!ProcessIdentity.matches(savedLaunch: capture.addingTimeInterval(-10), currentLaunch: capture,
                                        kernelStart: capture, capturedAt: capture),
               "Known changed launch dates cannot fall back to a different process")
        expect(RecoveryIdentity.candidate(titles: ["Changed title"], savedTitle: "Original") == 0,
               "A unique CG/AX geometry match survives a document title change")
        expect(RecoveryIdentity.candidate(titles: ["Other", "Saved"], savedTitle: "Saved") == 1,
               "Distinct titles disambiguate same-process windows sharing a parking frame")
        expect(RecoveryIdentity.candidate(titles: ["Saved", "Saved"], savedTitle: "Saved") == nil,
               "Identical title/geometry proxies cannot restore the wrong window")
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/desktop-checks/store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(url: folder.appendingPathComponent("original-arrangement.json"))
        let bridge = FakeBridge(), input = FakeScroll(), keys = FakeShortcuts()
        let connected = DisplayInfo.current(Array(NSScreen.screens.prefix(1)))
        let saved = SessionSnapshot(displays: connected, windows: bridge.windows, unchanged: [])
        try store.save(saved)
        let roundTrip = try store.load()
        expect(roundTrip?.id == saved.id, "Snapshot survives a disk encode/decode round trip")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.location)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Snapshot file is private to the user")
        for window in bridge.windows { bridge.frames[window.id]?.x += 200 }
        let desk = DeskController(bridge: bridge, shortcuts: keys, displayProvider: { connected }, scrollInput: input, store: store, preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        desk.scrollSpeed = 1
        desk.launch()
        expect(desk.mode == .paused && bridge.writes.isEmpty && !input.started, "Relaunch with pending recovery does not overwrite originals or tile again")
        let preserved = try store.load()
        expect(preserved?.id == saved.id, "Pending recovery snapshot identity remains intact")
        desk.confirmRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        let restored = try store.load()
        expect(bridge.restored && restored?.pending.isEmpty == true, "Saved windows rebind and restore after a simulated interrupted session")

        let failedStore = MemoryStore(); failedStore.failSave = true
        let other = FakeBridge(), otherInput = FakeScroll(), otherKeys = FakeShortcuts()
        let failed = DeskController(bridge: other, shortcuts: otherKeys, displayProvider: { connected }, scrollInput: otherInput, store: failedStore, preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        failed.scrollSpeed = 1
        failed.launch(); await drain()
        expect(other.writes.isEmpty && !otherInput.started && !otherKeys.registered, "Snapshot write failure prevents all window movement and removes input hooks")
        let failedTap = FakeScroll(); failedTap.failStart = true
        let tapDesk = DeskController(bridge: other, shortcuts: otherKeys, displayProvider: { connected }, scrollInput: failedTap, store: MemoryStore(), preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        tapDesk.scrollSpeed = 1
        tapDesk.launch(); await drain()
        expect(other.writes.isEmpty && !otherKeys.registered, "Input permission failure prevents automatic tiling")
        try Data("invalid snapshot".utf8).write(to: URL(fileURLWithPath: store.location))
        let corrupt = DeskController(bridge: other, shortcuts: otherKeys, displayProvider: { connected }, scrollInput: otherInput, store: store, preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        corrupt.scrollSpeed = 1
        corrupt.launch()
        expect(other.writes.isEmpty && corrupt.message.contains("Could not read"), "Unreadable recovery file is preserved without moving windows")
        let launchStore = MemoryStore(), launchBridge = FakeBridge(), launchInput = FakeScroll()
        let automatic = DeskController(bridge: launchBridge, shortcuts: FakeShortcuts(), displayProvider: { connected },
                                       scrollInput: launchInput, store: launchStore, preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        automatic.scrollSpeed = 1
        automatic.launch(); await drain()
        expect(automatic.mode == .live && launchStore.snapshot?.windows.count == launchBridge.windows.count,
               "Fresh launch saves and arranges eligible windows automatically")
        automatic.pauseAndRestore(); await waitUntil { automatic.pendingRestoreCount == 0 }
        print("PASS Persistent recovery, relaunch, private file, and startup failures")
    }

    static func checkSnapping() async throws {
        let smoothed = StripSmoothing.offset(from: 0, to: 100, seconds: 1.0 / 60)
        expect(smoothed > 0 && smoothed < 100, "Presentation smooths a contact spike instead of jumping")
        let reverse = StripSmoothing.offset(from: smoothed, to: -100, seconds: 1.0 / 60)
        expect(reverse < smoothed && reverse > -100, "Smoothing reverses immediately without overshooting")
        let sixty = (0..<6).reduce(0.0) { value, _ in StripSmoothing.offset(from: value, to: 100, seconds: 1.0 / 60) }
        let fast = (0..<12).reduce(0.0) { value, _ in StripSmoothing.offset(from: value, to: 100, seconds: 1.0 / 120) }
        expect(abs(sixty - fast) < 0.001 && sixty > 97, "Smoothing has the same short response at 60 and 120 Hz")
        expect(StripSmoothing.offset(from: 0, to: 100, seconds: 1) == 100, "Presentation converges exactly after input stops")
        let viewport = Frame(x: 0, y: 25, width: 1200, height: 875)
        var strip = StripState(items: (0..<4).map { .init(id: "s\($0)", title: "", appName: "Fixture", width: 800) }, edgeInset: 0)
        _ = strip.scroll(by: 430, in: viewport); strip.focusNearestToCenter(in: viewport)
        expect(strip.snapOffset(in: viewport) == 400 + StripState.gap, "Snap chooses the nearest edge that fully reveals the selected column")
        _ = strip.scroll(by: 350, in: viewport); strip.focusNearestToCenter(in: viewport)
        expect(strip.snapOffset(in: viewport) == 800 + StripState.gap, "Snap can align the opposite edge with the smaller correction")
        let animation = StripSnap(start: 430, target: 412)
        expect(animation.position(after: 0) == 430 && animation.position(after: animation.duration) == 412, "Snap starts at the current position and reaches its exact edge")
        let samples = (0...120).map { animation.position(after: animation.duration * Double($0) / 120) }
        expect(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 && $1 >= 412 }, "Snap settles monotonically without overshooting")
        let connected = [DisplayInfo(id: "snap-display", name: "Fixture", frame: Frame(x: 0, y: 0, width: 1200, height: 900), usable: viewport)]
        let bridge = FakeBridge(), input = FakeScroll()
        let desk = DeskController(bridge: bridge, shortcuts: FakeShortcuts(), displayProvider: { connected }, scrollInput: input, store: MemoryStore(), preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        desk.scrollSpeed = 1; desk.launch(); await waitUntil { !desk.preparing }
        input.onScroll?(150, CGPoint(x: 100, y: 100)); await drain()
        input.onFinish?(CGPoint(x: 100, y: 100))
        expect(desk.isSettling, "Finger lift starts animated edge settling")
        await waitUntil { !desk.isSettling }
        let focused = desk.placements.first { $0.id == desk.state.focusedID }!.frame
        expect(abs(focused.x - viewport.x) < 0.5 || abs(focused.maxX - viewport.maxX) < 0.5, "Settled native window aligns exactly to a screen edge")
        expect(bridge.positionBatches > 1, "Snapping advances through position batches rather than jumping to its target")
        input.onScroll?(120, CGPoint(x: 100, y: 100)); await drain(); input.onFinish?(CGPoint(x: 100, y: 100))
        await drain()
        // Native commits now use a common whole-point offset. The logical
        // animation position may be fractional and ahead of its last commit.
        let interrupted = -bridge.frames["w0"]!.x
        input.onBegin?(CGPoint(x: 100, y: 100)); input.onScroll?(20, CGPoint(x: 100, y: 100))
        expect(abs(desk.state.scrollOffset - interrupted - 20) < 0.01, "A new swipe interrupts snapping from its current position")
        await drain()
        expect(abs(desk.state.scrollOffset - interrupted - 20) < 0.01, "The cancelled snap cannot continue underneath the new swipe")
        let constrained = desk.state.focusedID!
        bridge.minimumWidths[constrained] = 1000
        desk.perform(.narrow); await waitUntil { !desk.isSettling }
        let constrainedFrame = desk.placements.first { $0.id == constrained }!.frame
        expect(constrainedFrame.width == viewport.width && constrainedFrame.x >= viewport.x && constrainedFrame.maxX <= viewport.maxX,
               "A native minimum wider than half promotes the window to a full-screen slot")
        let boundaryFocuses = bridge.focused.count
        input.onScroll?(150, CGPoint(x: 100, y: 100)); await drain()
        input.onFinish?(CGPoint(x: 100, y: 100)); await drain()
        input.onBegin?(CGPoint(x: 100, y: 100))
        input.onFinish?(CGPoint(x: 100, y: 100))
        await waitUntil { !desk.isSettling }
        let pitch = (viewport.width + StripState.gap) / 2
        expect(!desk.isMotionClockRunning && bridge.focused.count == boundaryFocuses + 1 &&
               abs(desk.state.scrollOffset / pitch - (desk.state.scrollOffset / pitch).rounded()) < 0.0001,
               "A new contact with no movement interrupts an old snap and settles once without an idle clock")
        desk.pauseAndRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        expect(bridge.restored, "Pausing during a snap restores all original frames")
        print("PASS Animated edge snapping, exact alignment, interruption, and restoration")
    }

    static func checkMotionSettingsPersistence() {
        let suite = "RibbonDeskTests.motion.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let input = FakeScroll()
        let desk = DeskController(bridge: FakeBridge(), shortcuts: FakeShortcuts(), scrollInput: input,
                                  store: MemoryStore(), preferences: preferences)
        expect(desk.motionSettings == .default && input.settings == .default,
               "Fresh isolated preferences configure safe motion defaults")
        desk.motionSettings = RibbonMotionSettings(speed: 4, sensitivity: 1.6, acceleration: 0.7, momentum: 0.1)
        let saved = desk.motionSettings
        let nextInput = FakeScroll()
        let next = DeskController(bridge: FakeBridge(), shortcuts: FakeShortcuts(), scrollInput: nextInput,
                                  store: MemoryStore(), preferences: preferences)
        expect(next.motionSettings == saved && nextInput.settings == saved,
               "All four motion controls survive relaunch and reach the input processor")
        next.scrollSpeed = 3
        expect(next.motionSettings.speed == 3 && nextInput.settings.speed == 3,
               "The legacy speed property updates the persisted motion settings once")
        next.motionSettings.speed = .infinity
        next.motionSettings.sensitivity = -4
        next.motionSettings.acceleration = 9
        next.motionSettings.momentum = -1
        expect(next.motionSettings == next.motionSettings.normalized() &&
               next.motionSettings.speed.isFinite && next.motionSettings.sensitivity == 0.5 &&
               next.motionSettings.acceleration == 1 && next.motionSettings.momentum == 0,
               "Nonfinite and out-of-range controls normalize before persistence and input")
        let clamped = DeskController(bridge: FakeBridge(), shortcuts: FakeShortcuts(), scrollInput: FakeScroll(),
                                    store: MemoryStore(), preferences: preferences)
        expect(clamped.motionSettings == next.motionSettings, "Normalized values, including native zero momentum, persist")
        next.resetMotionSettings()
        let reset = DeskController(bridge: FakeBridge(), shortcuts: FakeShortcuts(), scrollInput: FakeScroll(),
                                  store: MemoryStore(), preferences: preferences)
        expect(reset.motionSettings == .default && nextInput.settings == .default,
               "Reset restores and persists the defaults for every motion control")
        print("PASS Isolated motion settings persistence, validation, propagation, and reset")
    }

    static func checkNativeConstraintsAndQuickSwitching() async throws {
        let display = DisplayInfo(id: "native-constraints", name: "Fixture",
            frame: Frame(x: 0, y: 0, width: 1200, height: 900),
            usable: Frame(x: 0, y: 25, width: 1200, height: 875))
        let bridge = FakeBridge(), input = FakeScroll(), store = MemoryStore()
        bridge.constrainedMinimumWidths["w1"] = 720
        bridge.constrainedMaximumHeights["w2"] = 700
        let desk = DeskController(bridge: bridge, shortcuts: FakeShortcuts(), displayProvider: { [display] },
                                  scrollInput: input, store: store, preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        desk.launch(); await waitUntil { !desk.preparing && !desk.isSettling }
        expect(desk.mode == .live && bridge.frames["w1"]?.width == 1200 && bridge.frames["w2"]?.height == 700,
               "Native minimum width promotes only its window to full, and native maximum height stays usable")
        expect(bridge.windows.filter { $0.id != "w2" }.allSatisfy { bridge.frames[$0.id]?.height == 875 },
               "Unconstrained windows fill the complete usable height")
        expect(store.snapshot?.windows.map(\.original) == bridge.windows.map(\.original) && bridge.frameWrites < 20,
               "Constraint recovery is bounded and preserves every saved original")
        desk.select("w1"); await waitUntil { !desk.isSettling }
        let full = desk.placements.first { $0.id == "w1" }!.frame
        expect(full.x == display.usable.x && full.width == display.usable.width && bridge.focused.last == "w1",
               "Selecting a promoted full column reveals it completely before activation")
        let focusBefore = bridge.focused.count, writesBefore = bridge.frameWrites
        desk.select("w0"); desk.select("w2"); desk.select("w3")
        await waitUntil { !desk.isSettling }
        expect(bridge.focused.count == focusBefore + 1 && bridge.focused.last == "w3",
               "Rapid sidebar selections coalesce and activate only the latest target")
        expect(bridge.frameWrites - writesBefore < desk.managedWindowCount,
               "Quick switching skips native frames that already match the current layout")
        let settledWrites = bridge.frameWrites
        desk.select("w3"); await waitUntil { !desk.isSettling }
        expect(bridge.frameWrites == settledWrites && bridge.focused.last == "w3",
               "Reselecting an already revealed window activates without a resize or convergence pass")
        bridge.frames["w3"]?.height = 600
        desk.select("w3"); await waitUntil { !desk.isSettling }
        expect(bridge.frames["w3"]?.height == 875 && bridge.frameWrites > settledWrites,
               "A manual native resize is verified and corrected on the next explicit selection")
        desk.scrollHorizontally(by: -130); await waitUntil { !desk.isSettling && !desk.isMotionClockRunning }
        let batches = bridge.positionBatches
        await drain()
        expect(!desk.isMotionClockRunning && bridge.positionBatches == batches,
               "A stationary contact target stops the display clock and native writes")
        desk.finishHorizontalScroll(); await waitUntil { !desk.isSettling }
        let pitch = (display.usable.width + StripState.gap) / 2
        expect(abs(desk.state.scrollOffset / pitch - (desk.state.scrollOffset / pitch).rounded()) < 0.0001,
               "Native constraints still settle onto the half-screen grid")
        desk.pauseAndRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        let unrestored = bridge.windows.filter { bridge.frames[$0.id] != $0.original }.map {
            "\($0.id): actual=\(String(describing: bridge.frames[$0.id])) original=\($0.original)"
        }
        expect(bridge.restored && store.snapshot?.pending.isEmpty == true,
               "Native constraints and quick switching retain complete original-frame restoration; unmatched=\(unrestored), pending=\(String(describing: store.snapshot?.pending)), mode=\(desk.mode), message=\(desk.message)")

        let unsupported = FakeBridge(), otherStore = MemoryStore()
        unsupported.constrainedMinimumWidths["w1"] = 1500
        let other = DeskController(bridge: unsupported, shortcuts: FakeShortcuts(), displayProvider: { [display] },
                                   scrollInput: FakeScroll(), store: otherStore, preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        other.launch(); await waitUntil { !other.preparing && !other.isSettling }
        expect(other.mode == .live && other.state.items.first { $0.id == "w1" }?.isFloating == true &&
               unsupported.frames["w1"] == unsupported.windows[1].original,
               "A window that cannot fit either slot restores individually while its ribbon stays live")
        other.pauseAndRestore(); await waitUntil { other.pendingRestoreCount == 0 }
        expect(unsupported.restored, "Unsupported-window isolation preserves session restoration")
        print("PASS Native constraints, full-height fallback, latest target, idle clock, and restoration")
    }

    static func checkParkedInitialResize() async throws {
        let usable = Frame(x: 0, y: 25, width: 1856, height: 1055)
        let display = DisplayInfo(id: "parked-initial-resize", name: "Fixture",
            frame: Frame(x: 0, y: 0, width: 1920, height: 1080), usable: usable)
        let half = StripState.halfScreenWidth(in: usable)
        func makeBridge(staging: Bool) -> FakeBridge {
            let bridge = FakeBridge()
            bridge.windows.removeAll(); bridge.frames.removeAll(); bridge.stackingOrder.removeAll()
            for index in 0..<6 {
                let window = ManagedWindow(id: "w\(index)", number: UInt32(index + 1), pid: getpid(),
                    element: AXUIElementCreateApplication(pid_t(300000 + index)), original: usable,
                    title: "Fixture \(index)", appName: "Fixture", isLocal: index == 5)
                bridge.windows.append(window); bridge.frames[window.id] = usable
                bridge.stackingOrder.append(window.id)
            }
            bridge.resizeViewport = usable; bridge.stageParkedResizes = staging
            return bridge
        }
        func controller(_ bridge: FakeBridge, _ store: MemoryStore) -> DeskController {
            DeskController(bridge: bridge, shortcuts: FakeShortcuts(), displayProvider: { [display] },
                scrollInput: FakeScroll(), store: store, preferences: nil,
                pointerProvider: { CGPoint(x: -100000, y: -100000) })
        }

        // This negative control models the old move-before-shrink order. The
        // same six originals/native rules must reproduce the four parked full
        // promotions, so the successful run cannot pass by simply accepting AX.
        let legacy = makeBridge(staging: false), legacyStore = MemoryStore()
        let legacyDesk = controller(legacy, legacyStore)
        legacyDesk.launch(); await waitUntil { !legacyDesk.preparing && !legacyDesk.isSettling }
        expect(legacyDesk.mode == .live && legacy.offscreenResizeRefusals >= 4 &&
               (0..<4).allSatisfy { legacy.frames["w\($0)"]?.width == usable.width } &&
               (4..<6).allSatisfy { legacy.frames["w\($0)"]?.width == half },
               "Move-before-shrink reproduces four false full-width promotions at five-point parked origins")
        legacyDesk.pauseAndRestore(); await waitUntil { legacyDesk.pendingRestoreCount == 0 }
        expect(legacy.restored, "The offscreen-resize negative control restores all original native frames")

        let bridge = makeBridge(staging: true), store = MemoryStore()
        let desk = controller(bridge, store)
        desk.launch(); await waitUntil { !desk.preparing && !desk.isSettling }
        expect(desk.mode == .live && bridge.offscreenResizeRefusals == 0 &&
               bridge.windows.allSatisfy { bridge.frames[$0.id]?.width == half } &&
               desk.state.tiledItems.allSatisfy { $0.width == half },
               "Production resize staging retains half-width defaults for four parked and two visible full-size originals")
        let parked = desk.placements.filter(\.isParked)
        expect(parked.count == 4 && parked.allSatisfy { placement in
            let steps = bridge.nativeResizeSteps.filter { $0.id == placement.id }
            guard let resize = steps.firstIndex(where: { $0.operation == "resize" && $0.frame.width == half }),
                  let park = steps.lastIndex(where: { $0.operation == "move" && $0.frame == placement.frame }) else { return false }
            return resize < park && steps[resize].frame.x >= usable.x && steps[resize].frame.maxX <= usable.maxX
        }, "Each parked window shrinks inside its owning display before its final parked move")
        expect(store.snapshot?.windows.map(\.original) == bridge.windows.map(\.original) &&
               store.snapshot?.pending.count == 6 && bridge.frameWrites == 6,
               "Safe staging preserves six full-size originals and avoids controller constraint-promotion retries")
        desk.pauseAndRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        expect(bridge.restored && store.snapshot?.pending.isEmpty == true,
               "Half-width parked startup and safe resize staging retain complete original-frame recovery")

        let constrained = makeBridge(staging: true), constrainedStore = MemoryStore()
        constrained.constrainedMinimumWidths["w1"] = 1000
        let constrainedDesk = controller(constrained, constrainedStore)
        constrainedDesk.launch(); await waitUntil { !constrainedDesk.preparing && !constrainedDesk.isSettling }
        expect(constrainedDesk.mode == .live && constrained.offscreenResizeRefusals == 0 &&
               constrained.frames["w1"]?.width == usable.width &&
               constrained.windows.filter { $0.id != "w1" }.allSatisfy { constrained.frames[$0.id]?.width == half },
               "A genuine size refusal at the safe staging origin still promotes only that constrained window")
        constrainedDesk.pauseAndRestore(); await waitUntil { constrainedDesk.pendingRestoreCount == 0 }
        expect(constrained.restored && constrainedStore.snapshot?.pending.isEmpty == true,
               "Genuine constraints during parked resize staging preserve all original frames")
        print("PASS Parked initial resize, production staging order, false-minimum negative control, and restoration")
    }

    static func checkExplicitSwitchCancelsMomentum() async throws {
        let display = DisplayInfo(id: "switch-during-coast", name: "Fixture",
            frame: Frame(x: 0, y: 0, width: 1200, height: 900),
            usable: Frame(x: 0, y: 25, width: 1200, height: 875))
        let bridge = FakeBridge(), input = ProcessorScroll(), keys = FakeShortcuts()
        let desk = DeskController(bridge: bridge, shortcuts: keys, displayProvider: { [display] },
                                  scrollInput: input, store: MemoryStore(), preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        desk.motionSettings = .init(speed: 1, acceleration: 0, momentum: 0.35)
        desk.launch(); await waitUntil { !desk.preparing }
        let point = CGPoint(x: 100, y: 100)
        for index in 0..<2 {
            let time = 20 + Double(index)
            _ = input.processor.route(contacts: contacts(0.5), at: point, time: time)
            _ = input.processor.route(contacts: contacts(0.46), at: point, time: time + 0.02)
            _ = input.processor.route(contacts: [], at: point, time: time + 0.03, phase: .ended)
            await drain()
            expect(desk.state.scrollOffset > 96 && bridge.positionBatches > 0,
                   "The production processor is still coasting before an explicit window switch")
            let previousFocuses = bridge.focused.count
            if index == 0 { desk.select("w0") } else { desk.perform(.focusRight) }
            await waitUntil { !desk.isSettling }
            let selected = index == 0 ? "w0" : "w1"
            let offset = desk.state.scrollOffset, writes = bridge.writes.count
            try? await Task.sleep(nanoseconds: 650_000_000)
            expect(desk.state.focusedID == selected && desk.state.scrollOffset == offset &&
                   bridge.focused.last == selected && bridge.focused.count == previousFocuses + 1 &&
                   bridge.writes.count == writes && !desk.isMotionClockRunning && input.started && keys.registered,
                   "\(index == 0 ? "Sidebar selection" : "Keyboard switching") cancels coast, keeps its chosen window, and retains the live listener")
        }
        // Cancel before queued begin/delta delivery, too; an old gesture must
        // never re-enter after a synchronous sidebar choice.
        _ = input.processor.route(contacts: contacts(0.5), at: point, time: 23)
        _ = input.processor.route(contacts: contacts(0.46), at: point, time: 23.02)
        desk.select("w3")
        await waitUntil { !desk.isSettling }
        await drain()
        expect(desk.state.focusedID == "w3" && bridge.focused.last == "w3" && !desk.isMotionClockRunning,
               "Explicit selection invalidates gesture callbacks queued before the selection")
        desk.pauseAndRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        expect(bridge.restored && !input.started && !keys.registered,
               "Cancelling production momentum during switching preserves original-frame restoration")
        let demo = DeskController(preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        demo.startDemo(); demo.scrollHorizontally(by: 200); demo.finishHorizontalScroll()
        await drain()
        demo.select("read")
        let demoOffset = demo.state.scrollOffset
        try? await Task.sleep(nanoseconds: 350_000_000)
        expect(demo.state.focusedID == "read" && demo.state.scrollOffset == demoOffset &&
               !demo.isMotionClockRunning && !demo.isSettling && demo.inputCancellationRevision > 0,
               "An explicit demo selection cancels its previous snap and keeps the chosen column settled")
        let previousRevision = demo.inputCancellationRevision
        demo.startDemo()
        let restartedRevision = demo.inputCancellationRevision
        demo.pauseAndRestore()
        expect(restartedRevision > previousRevision && demo.inputCancellationRevision > restartedRevision,
               "Demo restart and pause invalidate local callbacks across session lifecycle resets")
        print("PASS Explicit sidebar/keyboard selection cancels production momentum and stale callbacks")
    }

    static func checkMotionAnimationLease() {
        var flag = true, writes: [Bool] = [], readCount = 0, failRestore = false
        let lease = MotionAppAnimations(read: { _ in readCount += 1; return .enabled(flag) }, write: { _, value in
            writes.append(value)
            if value && failRestore { return false }
            flag = value
            return true
        })
        lease.prepare(1); lease.prepare(1)
        expect(!flag && writes == [false], "One app animation lease covers all its windows in a batch")
        lease.restore()
        expect(flag && writes == [false, true], "The original animation flag is restored after the batch")
        lease.prepare(1); lease.restore()
        expect(readCount == 1 && flag, "Repeated frames reuse confirmed app capability without repeated AX reads")
        lease.prepare(1); failRestore = true; lease.restore(); lease.reset()
        expect(!flag, "A failed flag restoration remains owed rather than being cached as an original false")
        failRestore = false; lease.restore()
        expect(flag, "Restoration debt retries successfully")
        var disabledWrites = 0
        let disabled = MotionAppAnimations(read: { _ in .enabled(false) }, write: { _, _ in disabledWrites += 1; return true })
        disabled.prepare(1); disabled.restore()
        expect(disabledWrites == 0, "An app with animation already disabled is never altered")
        var reads = 0
        let transient = MotionAppAnimations(read: { _ in reads += 1; return reads == 1 ? .retry : .enabled(true) }, write: { _, _ in true })
        transient.prepare(1); transient.prepare(1); transient.restore()
        expect(reads == 2, "Transient AX read errors do not permanently disable the animation workaround")
        print("PASS App animation flag borrowing, caching, restoration debt, and retry")
    }

    static func checkSeparateDesktops() async throws {
        let connected = [DisplayInfo(id: "desktop-test", name: "Fixture display",
            frame: Frame(x: 0, y: 0, width: 1200, height: 900),
            usable: Frame(x: 0, y: 25, width: 1200, height: 875))]
        let display = connected[0].id
        let bridge = FakeBridge(), store = MemoryStore(), input = FakeScroll()
        bridge.activeDesktops = [display: 1]
        bridge.away = ["w2", "w3"]
        let desk = DeskController(bridge: bridge, shortcuts: FakeShortcuts(), displayProvider: { connected }, scrollInput: input, store: store, preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        desk.scrollSpeed = 1
        desk.launch(); await waitUntil { !desk.preparing }
        expect(desk.mode == .live && Set(desk.state.items.map(\.id)) == ["w0", "w1"], "Only the current desktop's windows enter its strip")
        expect(bridge.gatherCount == 0 && bridge.away == ["w2", "w3"], "Starting never transfers windows from other desktops")
        desk.perform(.full); await waitUntil { !desk.isSettling }
        desk.scrollHorizontally(by: 700); await drain(); desk.finishHorizontalScroll(); await waitUntil { !desk.isSettling }
        let firstOffset = desk.state.scrollOffset
        let firstOrder = desk.state.items.map(\.id)
        let savedFirst = store.snapshot!.windows.map(\.original)
        var allSavedBeforeWrites = true
        bridge.beforeWrite = { allSavedBeforeWrites = allSavedBeforeWrites && store.snapshot!.windows.count == 4 }
        bridge.activeDesktops = [display: 2]; bridge.away = ["w0", "w1"]
        desk.refreshActiveDesktopIfNeeded(); await waitUntil { !desk.preparing }
        expect(desk.mode == .live && Set(desk.state.items.map(\.id)) == ["w2", "w3"], "Switching desktops selects its independent strip without pausing")
        expect(allSavedBeforeWrites && store.snapshot?.windows.count == 4, "New desktop originals append to disk before movement")
        expect(Array(store.snapshot!.windows.prefix(2)).map(\.original) == savedFirst, "Visiting another desktop never overwrites earlier originals")
        desk.scrollHorizontally(by: 75); await drain(); desk.finishHorizontalScroll(); await waitUntil { !desk.isSettling }
        let secondOffset = desk.state.scrollOffset
        expect(firstOffset != secondOffset && firstOffset > 0, "Desktop fixture exercises distinct snapped offsets")
        bridge.activeDesktops = [display: 1]; bridge.away = ["w2", "w3"]
        desk.refreshActiveDesktopIfNeeded(); await waitUntil { !desk.preparing }
        expect(desk.state.scrollOffset == firstOffset && desk.state.items.map(\.id) == firstOrder, "Returning to a desktop retains its offset and column order")
        bridge.desktopOverviewActive = true
        let writes = bridge.writes.count
        input.onScroll?(100, .zero); desk.checkSession()
        expect(bridge.writes.count == writes && desk.state.scrollOffset == firstOffset, "Mission Control thumbnail transforms cannot move or overwrite the strip")
        bridge.desktopOverviewActive = false
        bridge.activeDesktops = [display: 2]; bridge.away = ["w0", "w1"]
        desk.refreshActiveDesktopIfNeeded(); await waitUntil { !desk.preparing }
        expect(desk.state.scrollOffset == secondOffset && bridge.gatherCount == 0, "Each desktop retains its own offset; no Space transfer runs")
        bridge.missing = ["w3"]
        desk.checkSession(); await waitUntil { !desk.preparing }
        expect(desk.mode == .live && desk.state.items.map(\.id) == ["w2"], "Closing a window reconciles its desktop instead of pausing every strip")
        desk.pauseAndRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        expect(store.snapshot?.pending.isEmpty == true && bridge.returnedSpaces.isEmpty,
               "Restoration visits all saved records without transferring desktops")
        expect(bridge.windows.filter { !bridge.missing.contains($0.id) }.allSatisfy { bridge.frames[$0.id] == $0.original }, "Every surviving visited-desktop window restores its original frame")

        let own = FakeBridge()
        own.windows[2].isLocal = true
        let selfDesk = DeskController(bridge: own, shortcuts: FakeShortcuts(), displayProvider: { connected }, scrollInput: FakeScroll(), store: MemoryStore(), preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        selfDesk.launch(); await waitUntil { !selfDesk.preparing }
        expect(selfDesk.state.focusedID == "w2" && selfDesk.placements.contains { $0.id == "w2" && !$0.isParked }, "RibbonDesk starts visibly inside its own ribbon column")
        selfDesk.pauseAndRestore(); await waitUntil { selfDesk.pendingRestoreCount == 0 }

        let snapshot = SessionSnapshot(displays: connected, windows: bridge.windows, unchanged: [])
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let encoded = try encoder.encode(snapshot)
        let roundTrip = try decoder.decode(SessionSnapshot.self, from: encoded)
        expect(roundTrip.windows.allSatisfy { $0.preservesDesktop == true && $0.capturedAt != nil }, "New snapshots retain the no-transfer policy and per-window capture time")
        var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        old["windows"] = (old["windows"] as! [[String: Any]]).map { item in
            var item = item
            for key in ["originalSpaces", "preservesDesktop", "capturedAt"] { item.removeValue(forKey: key) }
            return item
        }
        let legacy = try decoder.decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        expect(legacy.windows.allSatisfy { $0.originalSpaces == nil && $0.preservesDesktop == nil }, "Older recovery files remain readable for legacy restoration")
        print("PASS Separate desktops, saved offsets, append-before-write, self inclusion, overview, and legacy recovery")
    }

    static func checkNewWindowEnrollment() async throws {
        let connected = [DisplayInfo(id: "enrollment", name: "Fixture", frame: Frame(x: 0, y: 0, width: 1400, height: 900),
                                    usable: Frame(x: 0, y: 25, width: 1400, height: 875))]
        let bridge = FakeBridge(), input = FakeScroll(), store = MemoryStore()
        let desk = DeskController(bridge: bridge, shortcuts: FakeShortcuts(), displayProvider: { connected }, scrollInput: input, store: store, preferences: nil, pointerProvider: { CGPoint(x: -100000, y: -100000) })
        desk.launch(); await waitUntil { !desk.preparing }
        expect(!bridge.lastExclusions.contains("com.apple.systempreferences"), "System Settings is not excluded by default")
        let discoveryCount = bridge.discoveries
        for _ in 0..<5 { desk.checkSession() }
        expect(bridge.discoveries == discoveryCount, "Unchanged idle checks avoid AX rediscovery")
        let originals = store.snapshot!.windows.map(\.original)
        let order = desk.state.items.map(\.id)
        let frame = Frame(x: 150, y: 80, width: 715, height: 700)
        let settings = ManagedWindow(id: "settings", number: 101, pid: getpid(), element: AXUIElementCreateApplication(100101),
                                     original: frame, title: "System Settings", appName: "System Settings")
        bridge.windows.append(settings); bridge.frames[settings.id] = frame
        var savedBeforeMove = true
        desk.scrollHorizontally(by: 20); await drain()
        desk.checkSession()
        expect(bridge.discoveries == discoveryCount, "A newly opened window cannot trigger discovery during a swipe")
        desk.finishHorizontalScroll(); await waitUntil { !desk.isSettling }
        bridge.beforeWrite = { savedBeforeMove = savedBeforeMove && store.snapshot!.windows.contains { $0.id == settings.id } }
        desk.checkSession(); await waitUntil { !desk.preparing }
        expect(desk.state.items.contains { $0.id == settings.id } && savedBeforeMove,
               "A window opened after launch joins the current strip only after its original is saved")
        expect(Array(store.snapshot!.windows.prefix(originals.count)).map(\.original) == originals &&
               desk.state.items.filter { $0.id != settings.id }.map(\.id) == order,
               "Enrollment preserves existing originals and relative column order")
        bridge.beforeWrite = nil
        let refreshedCount = bridge.discoveries
        desk.checkSession(); await drain()
        expect(bridge.discoveries == refreshedCount, "An enrolled window does not repeatedly reset the strip")
        var dashboard = settings
        dashboard = ManagedWindow(id: "late-dashboard", number: 102, pid: getpid(), element: AXUIElementCreateApplication(getpid()),
                                  original: frame, title: "RibbonDesk", appName: "RibbonDesk", isLocal: true)
        bridge.windows.append(dashboard); bridge.frames[dashboard.id] = frame
        desk.checkSession(); await waitUntil { !desk.preparing }
        expect(desk.state.items.contains { $0.id == dashboard.id } && store.snapshot!.windows.contains { $0.id == dashboard.id },
               "A dashboard created or reopened after capture joins its desktop and receives its own saved original")
        bridge.missing.insert("settings"); desk.checkSession(); await waitUntil { !desk.preparing }
        expect(!desk.state.items.contains { $0.id == settings.id }, "Closing the new window removes its column")
        desk.pauseAndRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        expect(bridge.windows.filter { !bridge.missing.contains($0.id) }.allSatisfy { bridge.frames[$0.id] == $0.original } &&
               store.snapshot?.pending.isEmpty == true, "Incremental enrollment retains complete original-frame recovery")
        print("PASS New windows, idle-only discovery, Settings inclusion, stable order, and recovery")
    }

    static func checkPointerFocusAtSettlement() async throws {
        let display = DisplayInfo(id: "pointer", name: "Fixture", frame: Frame(x: 0, y: 0, width: 1200, height: 900),
                                  usable: Frame(x: 0, y: 25, width: 1200, height: 875))
        let bridge = FakeBridge(), input = FakeScroll()
        var pointer = CGPoint(x: 900, y: 100)
        let desk = DeskController(bridge: bridge, shortcuts: FakeShortcuts(), displayProvider: { [display] },
                                  scrollInput: input, store: MemoryStore(), preferences: nil, pointerProvider: { pointer })
        desk.launch(); await waitUntil { !desk.isSettling && !desk.preparing }
        desk.beginHorizontalScroll(); desk.scrollHorizontally(by: 40); await drain()
        desk.finishHorizontalScroll()
        await waitUntil { !desk.isSettling }
        expect(desk.state.scrollOffset == 0 && bridge.focused.last == "w1" && desk.state.focusedID == "w1",
               "The right half under the pointer activates even when center selection would prefer the left half")
        expect(pointer == CGPoint(x: 900, y: 100), "Settling never warps the pointer")
        pointer = CGPoint(x: 100, y: 100)
        desk.beginHorizontalScroll(); desk.scrollHorizontally(by: 400); await drain()
        let focuses = bridge.focused.count
        desk.finishHorizontalScroll(completion: .init(directTravel: 400, releaseVelocity: 1000))
        try? await Task.sleep(nanoseconds: 25_000_000)
        pointer = CGPoint(x: 900, y: 100)
        await waitUntil { !desk.isSettling }
        let pitch = (display.usable.width + StripState.gap) / 2
        expect(desk.state.scrollOffset == pitch && bridge.focused.last == "w2" && bridge.focused.count == focuses + 1,
               "The pointer is sampled after the snap finishes, with one focus and no second offset change")
        pointer = CGPoint(x: display.usable.width / 2, y: 100)
        desk.beginHorizontalScroll(); desk.scrollHorizontally(by: 20); await drain(); desk.finishHorizontalScroll()
        await waitUntil { !desk.isSettling }
        expect(bridge.focused.last == "w1" && desk.state.scrollOffset == pitch,
               "The central air gap falls back to the settled visible selection rather than an edge handle")
        desk.toggleFloating("w3"); await waitUntil { !desk.isSettling }
        bridge.topmostID = "w3"; pointer = CGPoint(x: 900, y: 100)
        desk.beginHorizontalScroll(); desk.scrollHorizontally(by: -20); await drain(); desk.finishHorizontalScroll()
        await waitUntil { !desk.isSettling }
        expect(bridge.focused.last == "w1", "A floating panel under the pointer does not select a tiled window behind it")
        bridge.topmostID = nil
        desk.toggleFloating("w3"); await waitUntil { !desk.isSettling }
        let explicitFocuses = bridge.focused.count
        desk.beginHorizontalScroll(); desk.scrollHorizontally(by: -250); await drain(); desk.finishHorizontalScroll()
        desk.perform(.first)
        await waitUntil { !desk.isSettling }
        try? await Task.sleep(nanoseconds: 230_000_000)
        expect(bridge.focused.last == "w0" && desk.state.focusedID == "w0" && bridge.focused.count == explicitFocuses + 1,
               "An explicit keyboard target cancels a pending pointer-focus settlement")
        desk.pauseAndRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        expect(bridge.restored, "Pointer focus and interrupted settles preserve every original frame")
        expect(DeskController.accessibilityPoint(from: CGPoint(x: -900, y: 1200), primaryTop: 900) == CGPoint(x: -900, y: -300) &&
               DeskController.accessibilityPoint(from: CGPoint(x: 400, y: -300), primaryTop: 900) == CGPoint(x: 400, y: 1200),
               "One primary-screen transform handles negative and vertically arranged display coordinates")
        print("PASS Pointer focus at final frames, right-half hit, pointer movement, gaps, floating panels, and explicit priority")
    }

    static func checkPointerAndKeyboardDisplayOwnership() async throws {
        let main = DisplayInfo(id: "main-pointer", name: "Main", frame: Frame(x: 0, y: 0, width: 1200, height: 900),
                               usable: Frame(x: 0, y: 25, width: 1200, height: 875))
        let other = DisplayInfo(id: "left-pointer", name: "Left", frame: Frame(x: -1200, y: -400, width: 1200, height: 900),
                                usable: Frame(x: -1200, y: -375, width: 1200, height: 875))
        let empty = DisplayInfo(id: "empty-pointer", name: "Empty", frame: Frame(x: 1200, y: 0, width: 1200, height: 900),
                                usable: Frame(x: 1200, y: 25, width: 1200, height: 875))
        let bridge = FakeBridge(), keys = FakeShortcuts()
        for index in 2..<4 {
            let old = bridge.windows[index]
            let frame = Frame(x: -1100 + Double(index * 50), y: -300, width: 700, height: 500)
            bridge.windows[index] = ManagedWindow(id: old.id, number: old.number, pid: old.pid, element: old.element,
                original: frame, title: old.title, appName: old.appName)
            bridge.frames[old.id] = frame
        }
        let extraFrame = Frame(x: 500, y: 100, width: 700, height: 500)
        let extra = ManagedWindow(id: "w4", number: 5, pid: getpid(), element: AXUIElementCreateApplication(100004),
                                  original: extraFrame, title: "Fixture", appName: "Fixture")
        bridge.windows.append(extra); bridge.frames[extra.id] = extraFrame
        var pointer = CGPoint(x: -300, y: -200)
        let desk = DeskController(bridge: bridge, shortcuts: keys, displayProvider: { [main, other, empty] },
                                  scrollInput: FakeScroll(), store: MemoryStore(), preferences: nil, pointerProvider: { pointer })
        desk.launch(); await waitUntil { !desk.preparing && !desk.isSettling }
        desk.scrollHorizontally(by: 20); await drain(); desk.finishHorizontalScroll()
        await waitUntil { !desk.isSettling }
        expect(bridge.focused.last == "w3" && desk.activeDisplayID == main.id && desk.state.scrollOffset == 0,
               "Moving the pointer to another current display focuses its right tile without moving either ribbon")
        pointer = CGPoint(x: 1800, y: 100)
        keys.onAction?(.focusLeft); await waitUntil { !desk.isSettling }
        expect(desk.activeDisplayID == other.id && bridge.focused.last == "w2",
               "Keyboard navigation follows the frontmost managed window even when the pointer is on an empty monitor")
        bridge.frontmostID = nil
        keys.onAction?(.focusRight); await waitUntil { !desk.isSettling }
        expect(desk.activeDisplayID == other.id && bridge.focused.last == "w3",
               "Without a managed frontmost window, keyboard navigation retains its populated active ribbon")
        desk.perform(.first); await waitUntil { !desk.isSettling }
        desk.perform(.cycleWidth); await waitUntil { !desk.isSettling }
        expect(desk.placements.first { $0.id == "w2" }?.frame.width == other.usable.width,
               "The cycle action promotes a half-width column to full width")
        desk.perform(.cycleWidth); await waitUntil { !desk.isSettling }
        expect(desk.placements.first { $0.id == "w2" }?.frame.width == StripState.halfScreenWidth(in: other.usable),
               "The cycle action returns an unconstrained full-width column to half width")
        desk.perform(.jump2); await waitUntil { !desk.isSettling }
        expect(bridge.focused.last == "w3", "Numeric jump actions use the current ribbon's tiled order")
        desk.perform(.first); await waitUntil { !desk.isSettling }
        desk.perform(.last); await waitUntil { !desk.isSettling }
        expect(bridge.focused.last == "w3", "First and last actions select their current ribbon's endpoints")
        desk.pauseAndRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        expect(bridge.restored && bridge.gatherCount == 0, "Display-aware focus preserves originals and never transfers Spaces")
        print("PASS Pointer display ownership, frontmost keyboard routing, empty monitor fallback, and new shortcut actions")
    }

    static func checkShortFlickAndMotionBoundaries() async throws {
        let display = DisplayInfo(id: "motion-boundaries", name: "Fixture", frame: Frame(x: 0, y: 0, width: 1200, height: 900),
                                  usable: Frame(x: 0, y: 25, width: 1200, height: 875))
        let bridge = FakeBridge(), input = ProcessorScroll()
        let desk = DeskController(bridge: bridge, shortcuts: FakeShortcuts(), displayProvider: { [display] },
                                  scrollInput: input, store: MemoryStore(), preferences: nil,
                                  pointerProvider: { CGPoint(x: 100, y: 100) })
        desk.motionSettings = .init(speed: 1, sensitivity: 1, acceleration: 0, momentum: 0)
        desk.launch(); await waitUntil { !desk.preparing && !desk.isSettling }
        let point = CGPoint(x: 100, y: 100), pitch = (display.usable.width + StripState.gap) / 2
        _ = input.processor.route(contacts: contacts(0.5), at: point, time: 30)
        _ = input.processor.route(contacts: contacts(0.494), at: point, time: 30.01)
        _ = input.processor.route(contacts: [], at: point, time: 30.02, phase: .ended)
        await drain(); await waitUntil { !desk.isSettling }
        expect(desk.state.scrollOffset == pitch && bridge.focused.last == "w1",
               "A real short-flick callback sequence advances one half-screen boundary instead of snapping back")
        let completed = bridge.focused.count
        _ = input.processor.route(contacts: contacts(0.5), at: point, time: 31)
        _ = input.processor.route(contacts: [], at: point, time: 31.02, phase: .ended)
        await drain()
        expect(desk.state.scrollOffset == pitch && bridge.focused.count == completed,
               "A contact with no horizontal movement cannot invent a snap or focus activation")
        let raiseCount = bridge.raised.count
        desk.beginHorizontalScroll(); desk.scrollHorizontally(by: 250); await drain()
        let ahead = desk.state.scrollOffset
        desk.scrollHorizontally(by: 200)
        await waitUntil { !desk.isSettling }
        desk.scrollHorizontally(by: -30)
        expect(abs(desk.state.scrollOffset - ahead - 170) < 0.0001,
               "Direct reversal preserves the exact accumulated finger travel without an interpolation target")
        await drain()
        let rightward = bridge.positionOrders.last ?? []
        expect(rightward == rightward.sorted { Int($0.dropFirst())! > Int($1.dropFirst())! },
               "Physical rightward motion writes rightmost leading windows before their left neighbors")
        desk.scrollHorizontally(by: 280); await drain()
        let leftward = bridge.positionOrders.last ?? []
        expect(leftward == leftward.sorted { Int($0.dropFirst())! < Int($1.dropFirst())! },
               "Physical leftward motion writes leftmost leading windows before their right neighbors")
        expect(bridge.raised.count == raiseCount,
               "Continuous movement performs no intermediate raises or application activation")
        desk.finishHorizontalScroll(); await waitUntil { !desk.isSettling }
        let writes = bridge.frameWrites, stableRaises = bridge.raised.count
        await drain()
        expect(bridge.frameWrites == writes && bridge.raised.count == stableRaises && !desk.isMotionClockRunning,
               "A settled ribbon has no continuing resize, stacking, or display-clock work")
        desk.pauseAndRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        expect(bridge.restored, "Short flicks and fast reversals retain complete original-frame restoration")
        print("PASS Production short flicks, no-motion contacts, reversal, leading-edge ordering, bounded stacking, and idle work")
    }

    static func checkCoalescedMotionScheduling() async throws {
        let display = DisplayInfo(id: "manual-external", name: "Fixture", frame: Frame(x: 0, y: 0, width: 1200, height: 900),
                                  usable: Frame(x: 0, y: 25, width: 1200, height: 875))
        let bridge = FakeBridge()
        var now = 100.0, displayReads = 0, clocks: [ManualFrameClock] = []
        let desk = DeskController(bridge: bridge, shortcuts: FakeShortcuts(), displayProvider: {
            displayReads += 1; return [display]
        }, scrollInput: FakeScroll(), store: MemoryStore(), preferences: nil,
            pointerProvider: { CGPoint(x: -100000, y: -100000) }, motionTime: { now },
            motionClockFactory: { displayID, tick in
                let clock = ManualFrameClock(displayID: displayID, tick: tick); clocks.append(clock); return clock
            })
        desk.launch(); await waitUntil { !desk.preparing && !desk.isSettling }
        let reads = (displayReads, bridge.desktopReads, bridge.visibleReads, bridge.availableReads)
        let initialRaises = bridge.raised.count
        var publications = 0
        let subscription = desk.$placements.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        bridge.holdMotionBatches = true
        desk.beginHorizontalScroll(); desk.scrollHorizontally(by: 100.2)
        for _ in 0..<20 { desk.scrollHorizontally(by: 0.05) }
        await waitUntil { bridge.positionBatches == 1 }
        expect(clocks.isEmpty && bridge.positionTargets.first?["w0"]?.x == -101,
               "Direct input coalesces on one main-runloop commit with no interpolation clock or fractional target")
        expect(publications == 0, "An uncommitted native batch cannot publish an ahead-of-windows UI preview")
        for _ in 0..<20 { now += 1.0 / 60; desk.scrollHorizontally(by: 5.025) }
        desk.checkSession()
        expect(bridge.positionBatches == 1 && bridge.maximumMotionBatches == 1,
               "A delayed provider keeps one shared in-flight frame while new input coalesces")
        expect((displayReads, bridge.desktopReads, bridge.visibleReads, bridge.availableReads) == reads,
               "Direct motion does not enumerate displays, Spaces, or native window inventory")
        bridge.releaseMotionBatch()
        await waitUntil { bridge.positionBatches == 2 }
        expect(bridge.positionTargets.last?["w0"]?.x == -desk.state.scrollOffset.rounded(),
               "Barrier completion consumes the latest rounded target without stale frames or an extra display-refresh wait")
        desk.scrollHorizontally(by: 7.1)
        bridge.holdMotionBatches = false; bridge.releaseMotionBatch()
        await waitUntil { bridge.positionBatches == 3 && !desk.isSettling }
        let stableBatches = bridge.positionBatches
        await drain()
        expect(bridge.maximumMotionBatches == 1 && bridge.positionBatches == stableBatches && clocks.isEmpty,
               "The latest-input follow-up finishes once and performs no continuing idle work")
        expect(bridge.positionTargets.flatMap { $0.values }.allSatisfy { $0.x == $0.x.rounded() },
               "Every native window receives the same whole-point strip translation")
        let baseTargets = bridge.positionTargets[0], nextTargets = bridge.positionTargets[1]
        expect(abs((nextTargets["w0"]!.x - baseTargets["w0"]!.x) -
                   (nextTargets["w1"]!.x - baseTargets["w1"]!.x)) < 0.0001,
               "Neighboring nonparked windows move by exactly equal deltas rather than rounding independently")
        desk.scrollHorizontally(by: 0.01); await waitUntil { !desk.isSettling }
        expect(bridge.positionBatches == stableBatches,
               "Sub-point input accumulates logically without redundant native writes to the same coordinate")
        let beforePublications = publications, beforeBatches = bridge.positionBatches
        for _ in 0..<20 {
            now += 1.0 / 120; desk.scrollHorizontally(by: 2)
            await waitUntil { !desk.isSettling }
        }
        expect(bridge.positionBatches - beforeBatches == 20 && publications - beforePublications <= 4,
               "Input commits directly while completed dashboard previews publish at bounded 15 Hz")
        expect(bridge.raised.count == initialRaises &&
               (displayReads, bridge.desktopReads, bridge.visibleReads, bridge.availableReads) == reads,
               "Continuous drag/coast movement performs no raising, topology inspection, or inventory reads")
        desk.finishHorizontalScroll()
        expect(clocks.last?.displayID == display.id,
               "Settlement alone uses a display clock pinned to the ribbon's owning display")
        for _ in 0..<30 where desk.isSettling {
            now += 1.0 / 60; clocks.last?.fire(); await waitUntil { bridge.activeMotionBatches == 0 }
        }
        await waitUntil { !desk.isSettling }
        expect(desk.placements.allSatisfy { bridge.frames[$0.id] == $0.frame } && bridge.focused.last == desk.state.focusedID,
               "Final native validation publishes exact settled frames and retains pointer-focus fallback")
        expect(displayReads > reads.0 && bridge.desktopReads > reads.1,
               "Settled commits still validate display topology and current Space")
        desk.pauseAndRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        expect(bridge.restored, "Direct coalesced commits and bounded UI publication preserve original-frame restoration")
        print("PASS Direct integer commits, one shared barrier, latest intent, no mid-motion raises/inventory, bounded UI, and final validation")
    }

    static func checkSettlementWaitsForCurrentFrame() async throws {
        let display = DisplayInfo(id: "settle-barrier", name: "Fixture", frame: Frame(x: 0, y: 0, width: 1200, height: 900),
                                  usable: Frame(x: 0, y: 25, width: 1200, height: 875))
        let bridge = FakeBridge()
        var now = 100.0, clocks: [ManualFrameClock] = []
        let desk = DeskController(bridge: bridge, shortcuts: FakeShortcuts(), displayProvider: { [display] },
            scrollInput: FakeScroll(), store: MemoryStore(), preferences: nil,
            pointerProvider: { CGPoint(x: -100000, y: -100000) }, motionTime: { now },
            motionClockFactory: { displayID, tick in
                let clock = ManualFrameClock(displayID: displayID, tick: tick); clocks.append(clock); return clock
            })
        desk.launch(); await waitUntil { !desk.preparing && !desk.isSettling }
        desk.beginHorizontalScroll(); desk.scrollHorizontally(by: 100)
        await waitUntil { !desk.isSettling }
        bridge.holdMotionBatches = true; desk.scrollHorizontally(by: 300)
        await waitUntil { bridge.activeMotionBatches == 1 }
        desk.scrollHorizontally(by: 200); desk.finishHorizontalScroll()
        expect(clocks.isEmpty && desk.isSettling,
               "Finger lift defers snap initialization while a newer native frame is still in flight")
        let snapBatchStart = bridge.positionTargets.count
        now += 0.02; bridge.holdMotionBatches = false; bridge.releaseMotionBatch()
        await waitUntil { clocks.last?.running == true }
        let raisesBeforeSnap = bridge.raised.count
        now += 0.01; clocks.last?.fire(); await waitUntil { bridge.activeMotionBatches == 0 }
        for _ in 0..<30 where desk.isSettling {
            now += 1.0 / 60; clocks.last?.fire(); await waitUntil { bridge.activeMotionBatches == 0 }
        }
        await waitUntil { !desk.isSettling }
        let offsets = bridge.positionTargets.dropFirst(snapBatchStart).compactMap { $0["w1"].map { 604 - $0.x } }
        expect(!offsets.isEmpty && offsets.allSatisfy { $0 >= 400 && $0 <= 604 } &&
               zip(offsets, offsets.dropFirst()).allSatisfy { $0 <= $1 },
               "Snap starts from the just-completed 400-point frame and never jumps backward toward the older 100-point frame")
        expect(desk.state.scrollOffset == 604 && bridge.positionTargets.dropFirst(snapBatchStart).flatMap { $0.values }.allSatisfy { $0.x == $0.x.rounded() },
               "The delayed handoff reaches its exact grid endpoint using common integer coordinates")
        expect(bridge.raised.count <= raisesBeforeSnap + 1,
               "Snap performs stacking only at final verified layout, never per motion frame")
        desk.pauseAndRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        expect(bridge.restored, "Deferred settlement keeps original-frame restoration complete")
        print("PASS In-flight finger lift, monotonic snap handoff, integer frames, final stacking, and restoration")
    }

    static func checkMotionInterruptionInvalidation() async throws {
        let display = DisplayInfo(id: "interrupt-clock", name: "Fixture", frame: Frame(x: 0, y: 0, width: 1200, height: 900),
                                  usable: Frame(x: 0, y: 25, width: 1200, height: 875))
        let bridge = FakeBridge(), input = FakeScroll()
        var now = 100.0, clocks: [ManualFrameClock] = []
        let desk = DeskController(bridge: bridge, shortcuts: FakeShortcuts(), displayProvider: { [display] },
                                  scrollInput: input, store: MemoryStore(), preferences: nil,
                                  pointerProvider: { CGPoint(x: -100000, y: -100000) }, motionTime: { now },
                                  motionClockFactory: { displayID, tick in
            let clock = ManualFrameClock(displayID: displayID, tick: tick); clocks.append(clock); return clock
        })
        desk.launch(); await waitUntil { !desk.preparing && !desk.isSettling }
        bridge.holdMotionBatches = true
        desk.beginHorizontalScroll(); desk.scrollHorizontally(by: 200); now += 0.1; clocks.last?.fire()
        await waitUntil { bridge.positionBatches == 1 }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        expect(!desk.isMotionClockRunning && !input.started && !desk.controlsEnabled,
               "A Space notification immediately stops old-desktop motion before delayed discovery")
        bridge.releaseMotionBatch(); bridge.holdMotionBatches = false
        await waitUntil { !desk.preparing && !desk.isSettling }
        expect(desk.mode == .live && input.started, "A canceled Space animation refreshes and safely resumes its current ribbon")
        desk.beginHorizontalScroll(); desk.scrollHorizontally(by: 50); now += 0.1; clocks.last?.fire()
        await waitUntil { !desk.isSettling }
        bridge.desktopOverviewActive = true; clocks.last?.fire()
        let batches = bridge.positionBatches
        desk.scrollHorizontally(by: 50); clocks.last?.fire()
        expect(!desk.isMotionClockRunning && !desk.controlsEnabled && bridge.positionBatches == batches,
               "Mission Control interruption cancels the clock and prevents further native writes")
        bridge.desktopOverviewActive = false; desk.checkSession()
        await waitUntil { !desk.preparing && !desk.isSettling }
        expect(desk.controlsEnabled, "The current ribbon revalidates after Mission Control exits")
        desk.scrollHorizontally(by: 60); now += 0.1; clocks.last?.fire()
        await waitUntil { !desk.isSettling }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        expect(desk.mode == .paused && !desk.isMotionClockRunning && !input.started,
               "A display topology notification immediately suspends motion")
        desk.confirmRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        expect(bridge.restored, "Interrupted batches remain recoverable without stale writes after restoration")
        print("PASS Immediate Space/overview/topology invalidation, refresh, and restoration")
    }

    static func checkParkedWindowStacking() async throws {
        let main = DisplayInfo(id: "stack-main", name: "Main", frame: Frame(x: 0, y: 0, width: 1200, height: 900),
                               usable: Frame(x: 0, y: 25, width: 1200, height: 875))
        let other = DisplayInfo(id: "stack-other", name: "Other", frame: Frame(x: 1200, y: 0, width: 1200, height: 900),
                                usable: Frame(x: 1200, y: 25, width: 1200, height: 875))
        let bridge = FakeBridge()
        for index in 4..<7 {
            let frame = index == 6 ? Frame(x: 100, y: 100, width: 240, height: 200)
                : Frame(x: 1300 + Double(index * 20), y: 100, width: 700, height: 500)
            let window = ManagedWindow(id: "w\(index)", number: UInt32(index + 1), pid: getpid(),
                element: AXUIElementCreateApplication(pid_t(100000 + index)), original: frame,
                title: "Fixture", appName: "Fixture")
            bridge.windows.append(window); bridge.frames[window.id] = frame; bridge.stackingOrder.append(window.id)
        }
        bridge.stackingLevels["w6"] = 1
        bridge.simulateFrontmostAppRaiseRestriction = true
        bridge.simulatedAppGroups = ["w0": "incoming", "w1": "incoming", "w2": "incoming",
                                     "w3": "frontmost", "w4": "other", "w5": "other", "w6": "floating"]
        let desk = DeskController(bridge: bridge, shortcuts: FakeShortcuts(), displayProvider: { [main, other] },
                                  scrollInput: FakeScroll(), store: MemoryStore(), preferences: nil,
                                  pointerProvider: { CGPoint(x: -100000, y: -100000) })
        desk.launch(); await waitUntil { !desk.preparing && !desk.isSettling }
        desk.toggleFloating("w6"); await waitUntil { !desk.isSettling }
        desk.select("w3"); await waitUntil { !desk.isSettling }
        try await bridge.raiseVisibleWindows([bridge.windows[1]])
        expect(bridge.stackingOrder.firstIndex(of: "w3")! < bridge.stackingOrder.firstIndex(of: "w1")!,
               "The fake models AXRaise's cross-app limitation instead of promising a frontmost-app stacking guarantee")
        let unrelated = Set(["w4", "w5", "w6"])
        let otherOrder = bridge.stackingOrder.filter { unrelated.contains($0) }
        let untouchedFrames = Dictionary(uniqueKeysWithValues: unrelated.map { ($0, bridge.frames[$0]!) })
        let focuses = bridge.focused.count, writes = bridge.writes.count, raises = bridge.raised.count
        expect(bridge.stackingOrder.firstIndex(of: "w3")! < bridge.stackingOrder.firstIndex(of: "w1")!,
               "Fixture starts with the outgoing focused surface above the incoming tile")
        desk.beginHorizontalScroll(); desk.scrollHorizontally(by: -1000)
        await waitUntil { !desk.isSettling && !desk.isMotionClockRunning }
        let outgoing = desk.placements.first { $0.id == "w3" }!
        let incoming = desk.placements.first { $0.id == "w1" }!
        let overlapPoint = CGPoint(x: 900, y: 400)
        expect(outgoing.isParked && !incoming.isParked && outgoing.frame.contains(overlapPoint) && incoming.frame.contains(overlapPoint),
               "Fast reversal parks the outgoing surface over a real incoming tile at the occupied display seam")
        let topAtOverlap = bridge.effectiveStackingOrder.first { bridge.frames[$0]?.contains(overlapPoint) == true }
        expect(topAtOverlap == "w3" && bridge.raised.count == raises,
               "Continuous movement does not attempt to solve the known side-by-side clamp overlap with unreliable cross-app raises")
        expect(bridge.focused.count == focuses && bridge.frontmostID == "w3",
               "A gesture leaves application activation and keyboard focus unchanged until settlement")
        expect(bridge.stackingOrder.filter { unrelated.contains($0) } == otherOrder &&
               unrelated.allSatisfy { bridge.frames[$0] == untouchedFrames[$0] } &&
               bridge.writes.dropFirst(writes).allSatisfy { !unrelated.contains($0.0) } &&
               bridge.raised.dropFirst(raises).allSatisfy { Set($0).isDisjoint(with: unrelated) },
               "Other-display windows and the floated surface retain their order, frames, and exclusion from motion/raises")
        expect(bridge.effectiveStackingOrder.first == "w6" && bridge.stackingLevels["w6"] == 1,
               "A native floating level remains above normal windows during movement")
        let stableRaises = bridge.raised.count
        desk.scrollHorizontally(by: 12); await waitUntil { !desk.isSettling && !desk.isMotionClockRunning }
        expect(bridge.raised.count == stableRaises,
               "Movement within the same visibility set performs no intermediate raises")
        desk.finishHorizontalScroll(); await waitUntil { !desk.isSettling }
        expect(bridge.raised.count == stableRaises + 1 && bridge.focused.last == desk.state.focusedID,
               "Verified settlement performs one ordered stacking pass and explicitly focuses its selected window")
        desk.pauseAndRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        expect(bridge.restored && bridge.gatherCount == 0, "Stacking corrections retain original frames and never transfer a Space")
        print("PASS Honest cross-app raise limitation, no mid-motion stacking, final selection, and display/floating preservation")
    }

    static func checkStrictStaleElementRecovery() async throws {
        let display = DisplayInfo(id: "strict-refresh", name: "Fixture", frame: Frame(x: 0, y: 0, width: 1200, height: 900),
                                  usable: Frame(x: 0, y: 25, width: 1200, height: 875))
        func controller(_ bridge: FakeBridge, _ store: MemoryStore) -> DeskController {
            DeskController(bridge: bridge, shortcuts: FakeShortcuts(), displayProvider: { [display] },
                scrollInput: FakeScroll(), store: store, preferences: nil,
                pointerProvider: { CGPoint(x: -100000, y: -100000) })
        }
        let bridge = FakeBridge(), store = MemoryStore()
        let live = controller(bridge, store)
        live.launch(); await waitUntil { !live.preparing && !live.isSettling }
        let originals = store.snapshot!.windows.map(\.original)
        bridge.staleProxyIDs.insert("w1"); bridge.frames["w1"]?.height = 600
        live.select("w1"); await waitUntil { !live.isSettling }
        expect(live.mode == .live && bridge.refreshCalls == ["w1"] && bridge.proxyFailures == 1 && bridge.focused.last == "w1",
               "A typed stale-frame failure resolves the exact saved window once and retries its target with a fresh proxy")
        bridge.staleEligibilityIDs.insert("w2"); bridge.frames["w2"]?.height = 600
        live.select("w2"); await waitUntil { !live.isSettling }
        expect(live.mode == .live && bridge.refreshCalls.filter { $0 == "w2" }.count == 1 && bridge.focused.last == "w2",
               "A stale layout eligibility gate can refresh one exact visible native identity before setting its frame")
        live.select("w3"); await waitUntil { !live.isSettling }
        bridge.staleEligibilityIDs.insert("w3")
        live.select("w3"); await waitUntil { !live.isSettling }
        expect(live.mode == .live && bridge.refreshCalls.filter { $0 == "w3" }.count == 1 && bridge.focused.last == "w3",
               "A stale focus eligibility gate refreshes once even when native frames already match")
        let refreshCount = bridge.refreshCalls.count
        live.beginHorizontalScroll(); live.scrollHorizontally(by: -40)
        await waitUntil { !live.isSettling }
        expect(bridge.refreshCalls.count == refreshCount, "Continuous native motion never resolves fresh Accessibility handles")
        live.finishHorizontalScroll(); await waitUntil { !live.isSettling }
        bridge.staleProxyIDs.insert("w0")
        live.pauseAndRestore(); await waitUntil { live.pendingRestoreCount == 0 }
        expect(bridge.restored && bridge.refreshCalls.filter { $0 == "w0" }.count == 1 && store.snapshot?.pending.isEmpty == true &&
               store.snapshot?.windows.map(\.original) == originals,
               "Restoration retries one stale proxy while preserving every original and clearing only completed restores")

        let wrong = FakeBridge(), wrongStore = MemoryStore(), wrongDesk = controller(wrong, wrongStore)
        wrongDesk.launch(); await waitUntil { !wrongDesk.preparing && !wrongDesk.isSettling }
        let saved = wrong.windows[1]
        wrong.staleProxyIDs.insert(saved.id)
        wrong.refreshOverrides[saved.id] = ManagedWindow(id: saved.id, number: 999, pid: saved.pid,
            element: AXUIElementCreateApplication(299999), original: saved.original, title: saved.title, appName: saved.appName)
        wrongDesk.pauseAndRestore(); await waitUntil { wrongDesk.pendingRestoreCount == 1 }
        expect(wrong.refreshCalls == [saved.id] && wrongStore.snapshot?.pending == [saved.id] && wrong.frames[saved.id] != saved.original,
               "A fresh proxy with a different native window number cannot retarget restoration or clear its recovery record")
        expect(WindowRefreshIdentity.exactCandidate(numbers: [saved.number, saved.number, nil], savedNumber: saved.number) == nil &&
               WindowRefreshIdentity.exactCandidate(numbers: [999, nil], savedNumber: saved.number) == nil,
               "Ambiguous and missing exact native identities refuse title/geometry fallback")
        wrong.refreshOverrides.removeAll(); wrongDesk.confirmRestore()
        await waitUntil { wrongDesk.pendingRestoreCount == 0 }
        expect(wrong.restored, "An explicitly retried restore can finish after exact identity becomes available")

        let persistent = FakeBridge(), persistentStore = MemoryStore(), persistentDesk = controller(persistent, persistentStore)
        persistentDesk.launch(); await waitUntil { !persistentDesk.preparing && !persistentDesk.isSettling }
        persistent.persistentProxyFailures.insert("w2")
        persistentDesk.pauseAndRestore(); await waitUntil { persistentDesk.pendingRestoreCount == 1 }
        expect(persistent.proxyFailures == 2 && persistent.refreshCalls == ["w2"] && persistentStore.snapshot?.pending == ["w2"],
               "A persistent stale-element failure gets one fresh retry and retains its saved original pending")
        persistent.persistentProxyFailures.removeAll(); persistentDesk.confirmRestore()
        await waitUntil { persistentDesk.pendingRestoreCount == 0 }
        expect(persistent.restored, "A later successful restore clears the retained original normally")

        let modal = FakeBridge(), modalStore = MemoryStore(), modalDesk = controller(modal, modalStore)
        modalDesk.launch(); await waitUntil { !modalDesk.preparing && !modalDesk.isSettling }
        let previousFocusCount = modal.focused.count
        modal.staleEligibilityIDs.insert("w1"); modal.rejectedRefreshIDs.insert("w1")
        modalDesk.select("w1"); await waitUntil { !modalDesk.isSettling }
        expect(modalDesk.mode == .live && !modalDesk.preparing && modal.focused.count == previousFocusCount && modal.refreshCalls == ["w1"],
               "Rejected fresh focus skips activation while completing settled/startup bookkeeping instead of leaving the controller preparing")
        modal.refreshCalls.removeAll()
        modal.staleEligibilityIDs.insert("w1"); modal.rejectedRefreshIDs.insert("w1"); modal.frames["w1"]?.height = 600
        modalDesk.select("w1"); await waitUntil { modalDesk.mode == .paused && modalDesk.pendingRestoreCount == 0 }
        expect(modal.refreshCalls == ["w1"] && !modal.focused.contains("w1") && modal.restored,
               "A fresh modal/ineligible proxy is refused; it cannot receive layout focus and original-frame recovery still completes")
        print("PASS Strict stale-element retry, layout/focus eligibility gates, identity refusal, persistent recovery, and no hot-path refresh")
    }

    static func checkRefreshRevalidatesNativeContext() async throws {
        let display = DisplayInfo(id: "refresh-context", name: "Fixture", frame: Frame(x: 0, y: 0, width: 1200, height: 900),
                                  usable: Frame(x: 0, y: 25, width: 1200, height: 875))
        let bridge = FakeBridge(), store = MemoryStore()
        let desk = DeskController(bridge: bridge, shortcuts: FakeShortcuts(), displayProvider: { [display] },
            scrollInput: FakeScroll(), store: store, preferences: nil,
            pointerProvider: { CGPoint(x: -100000, y: -100000) })
        desk.launch(); await waitUntil { !desk.preparing && !desk.isSettling }
        let originals = store.snapshot!.windows.map(\.original)
        bridge.staleEligibilityIDs.insert("w1"); bridge.holdRefresh = true
        desk.select("w1")
        await waitUntil { bridge.refreshCalls == ["w1"] }
        let frames = bridge.frames, focusCount = bridge.focused.count
        // Deliberately change the underlying context before any notification
        // invalidates the controller revision. Generation checks alone pass.
        bridge.activeDesktops = [display.id: 1]
        bridge.holdRefresh = false; bridge.releaseRefresh()
        await waitUntil { !desk.isSettling }
        expect(bridge.focused.count == focusCount && bridge.frames == frames && desk.mode == .live && !desk.preparing,
               "A Space change during fresh resolution prevents frame/focus use even before its notification arrives")
        expect(store.snapshot?.windows.map(\.original) == originals && store.snapshot?.pending.count == 4,
               "A rejected delayed refresh leaves saved identities/originals and pending restoration untouched")
        bridge.activeDesktops = [display.id: 0]
        desk.select("w1"); await waitUntil { !desk.isSettling }
        expect(bridge.refreshCalls == ["w1", "w1"] && bridge.focused.last == "w1",
               "The context-invalid result never replaces the old record; the next valid selection resolves it again")
        desk.pauseAndRestore(); await waitUntil { desk.pendingRestoreCount == 0 }
        expect(bridge.restored, "Delayed resolution and native-context refusal preserve complete original-frame recovery")

        let overviewBridge = FakeBridge(), overviewStore = MemoryStore()
        let overviewDesk = DeskController(bridge: overviewBridge, shortcuts: FakeShortcuts(), displayProvider: { [display] },
            scrollInput: FakeScroll(), store: overviewStore, preferences: nil,
            pointerProvider: { CGPoint(x: -100000, y: -100000) })
        overviewDesk.launch(); await waitUntil { !overviewDesk.preparing && !overviewDesk.isSettling }
        overviewBridge.staleEligibilityIDs.insert("w1"); overviewBridge.holdRefresh = true
        overviewDesk.select("w1")
        await waitUntil { overviewBridge.refreshCalls == ["w1"] }
        let overviewFrames = overviewBridge.frames
        overviewBridge.desktopOverviewActive = true
        overviewBridge.holdRefresh = false; overviewBridge.releaseRefresh()
        await waitUntil { !overviewDesk.isSettling }
        expect(overviewBridge.focused.isEmpty && overviewBridge.frames == overviewFrames &&
               overviewStore.snapshot?.pending.count == 4 && !overviewDesk.preparing,
               "Mission Control opening during fresh resolution prevents frame/focus use without relying on a Space notification")
        overviewBridge.desktopOverviewActive = false
        overviewDesk.select("w1"); await waitUntil { !overviewDesk.isSettling }
        expect(overviewBridge.refreshCalls == ["w1", "w1"] && overviewBridge.focused.last == "w1",
               "An overview-invalid result never replaces the record; normal selection resolves again after overview exits")
        overviewDesk.pauseAndRestore(); await waitUntil { overviewDesk.pendingRestoreCount == 0 }
        expect(overviewBridge.restored, "Overview interruption during fresh resolution preserves original-frame recovery")
        print("PASS Space/overview revalidation after asynchronous fresh resolution and recovery")
    }

    static func checkBoundedRuntimeCapture() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RibbonDeskDiagnostics-\(UUID().uuidString)")
        let destination = folder.appendingPathComponent("trace.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let diagnostics = RuntimeDiagnostics(destination: destination, allowLaunchMarker: false)
        diagnostics.record("disabled", [:]); diagnostics.flush()
        await drain()
        expect(!diagnostics.isCapturing && !FileManager.default.fileExists(atPath: destination.path),
               "Runtime diagnostics are off by default and create no file")
        diagnostics.startCapture(seconds: 0.1); diagnostics.record("old-session", [:])
        diagnostics.startCapture(seconds: 0.3)
        for index in 0..<4100 { diagnostics.record("new-session", ["index": index]) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        expect(diagnostics.isCapturing, "A previous capture's deadline cannot stop a newer trace")
        diagnostics.stopCapture()
        await waitUntil { FileManager.default.fileExists(atPath: destination.path) }
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as! [[String: Any]]
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        expect(!diagnostics.isCapturing && rows.count <= 4000 && !rows.contains { $0["kind"] as? String == "old-session" },
               "Capture restart clears prior rows and enforces its bounded row count")
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
               "The injected local diagnostics file is owner-readable and owner-writable only")
        diagnostics.startCapture(seconds: 0.1)
        await waitUntil { !diagnostics.isCapturing }
        diagnostics.flush(); await drain()
        expect(!diagnostics.isCapturing, "Timed diagnostics stop automatically without a runtime restart")
        print("PASS Explicit diagnostics, isolated destination, deadline renewal, row cap, and private output")
    }

    static func main() async {
        _ = NSApplication.shared
        checkEvents(); await checkDemo(); checkMotionAnimationLease(); checkMotionSettingsPersistence()
        do {
            try await checkFrameConvergence()
            try await checkLiveController()
            try await checkDelayedCancellation()
            await checkGlobalRouting()
            try await checkDisplaysAndSnapshots()
            try await checkPersistenceAndStartup()
            try await checkSeparateDesktops()
            try await checkNewWindowEnrollment()
            try await checkSnapping()
            try await checkNativeConstraintsAndQuickSwitching()
            try await checkParkedInitialResize()
            try await checkExplicitSwitchCancelsMomentum()
            try await checkPointerFocusAtSettlement()
            try await checkPointerAndKeyboardDisplayOwnership()
            try await checkShortFlickAndMotionBoundaries()
            try await checkParkedWindowStacking()
            try await checkCoalescedMotionScheduling()
            try await checkSettlementWaitsForCurrentFrame()
            try await checkMotionInterruptionInvalidation()
            try await checkStrictStaleElementRecovery()
            try await checkRefreshRevalidatesNativeContext()
            try await checkBoundedRuntimeCapture()
        }
        catch { failures += 1; print("FAIL \(error.localizedDescription)") }
        print("\(assertions) desktop assertions; \(failures) failures. Real AppKit view/controller; fake AX bridge. No user windows accessed.")
        exit(failures == 0 ? 0 : 1)
    }
}
