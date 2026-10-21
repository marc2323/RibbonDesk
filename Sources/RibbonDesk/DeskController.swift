import AppKit
import Combine
import RibbonCore

enum DeskMode: String {
    case disabled = "Disabled", demo = "Demo only", live = "Live session", paused = "Paused"
}

@MainActor
final class DeskController: ObservableObject {
    @Published private(set) var mode: DeskMode = .disabled
    private(set) var state = StripState()
    @Published private(set) var placements: [Placement] = []
    @Published private(set) var viewport = Frame(x: 0, y: 0, width: 1440, height: 900)
    @Published private(set) var message = "Save your arrangement and start a scrolling desktop."
    @Published private(set) var pendingRestoreCount = 0
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var activeDisplayID: String?
    @Published private(set) var unchanged: [WindowAccount] = []
    @Published var excludedBundleIDs = ""
    @Published var motionSettings = RibbonMotionSettings() {
        didSet {
            let normalized = motionSettings.normalized()
            if motionSettings != normalized { motionSettings = normalized }
            guard oldValue != normalized else { return }
            scrollInput.updateMotionSettings(normalized)
            if let data = try? JSONEncoder().encode(normalized) {
                preferences?.set(data, forKey: Self.motionSettingsKey)
            }
        }
    }
    var scrollSpeed: Double {
        get { motionSettings.speed }
        set { motionSettings.speed = newValue }
    }
    private static let motionSettingsKey = "RibbonDesk.motionSettings.v1"
    @Published private(set) var preparing = false
    @Published private(set) var inputCancellationRevision: UInt = 0
    var statusChanged: (() -> Void)?
    var snapshotLocation: String { store.location }
    var managedWindowCount: Int { records.count }
    var shortcutWarnings: [String] { shortcuts.registrationWarnings }
    var shortcutDiagnostics: ShortcutDiagnostics { shortcuts.diagnostics }
    var isSettling: Bool { snapAnimation != nil || pendingSnapTarget != nil || applyingLayout || commitScheduled || motionCommitQueued || motionTask != nil }
    var isMotionClockRunning: Bool { motionClock != nil }
    private let bridge: any WindowBridge
    private let shortcuts: any ShortcutHandling
    private let scrollInput: any GlobalScrollHandling
    private let store: any SessionPersisting
    private let preferences: UserDefaults?
    private let screens: @MainActor () -> [NSScreen]
    private let displayProvider: @MainActor () -> [DisplayInfo]
    /// The injected point already uses AX's global upper-left coordinate space.
    private let pointerProvider: @MainActor () -> CGPoint
    private let motionTime: @MainActor () -> TimeInterval
    private let motionClockFactory: @MainActor (String?, @escaping () -> Void) -> any FrameClockDriving
    private var records: [String: ManagedWindow] = [:]
    private var displayStrips: [String: StripState] = [:]
    private var desktopStrips: [String: StripState] = [:]
    private var currentDesktops: [String: UInt64] = [:]
    private var lastDiscoverySignature: Set<String> = []
    private var desktopRefreshTask: Task<Void, Never>?
    private var overviewWasActive = false
    private var snapshot: SessionSnapshot?
    private var touched: Set<String> = []
    private var lastApplied: [String: Frame] = [:]
    private var constrainedHeights: [String: Double] = [:]
    private var learnedMinimumWidths: [String: Double] = [:]
    private var constraintAttempts: [String: Int] = [:]
    private var capturedDisplays: [DisplayInfo] = []
    private var mayRestoreAutomatically = true
    private var commitScheduled = false
    private var commitGeneration: UInt = 0
    private var intentRevision: UInt = 0
    private var applyingLayout = false
    private var layoutTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var restoreReason = ""
    private var pendingFocus = false
    private var pendingRevealFocused = true
    private var pendingPointerFocus = false
    private var visibleColumns: [String: Set<String>] = [:]
    private var isPanning = false
    private var gestureDisplayID: String?
    private var gestureStartOffset: Double?
    private var gestureCompletion: RibbonSwipeCompletion?
    private var gestureFinished = false
    private var motionTask: Task<Void, Never>?
    private var motionCommitQueued = false
    private var pendingSnapTarget: Double?
    private var motionFramePending = false
    private var motionInFlightIDs: Set<String> = []
    private var busyMotionTicks = 0
    private var motionToken: UInt = 0
    private var motionRevision: UInt = .max
    private var motionClock: (any FrameClockDriving)?
    private var snapAnimation: (StripSnap, Double)?
    private var presentedOffset: Double?
    private var lastPreviewTime = -Double.infinity
    private var committedMotionPlacements: [Placement]?
    private var scrollPanel: LiveScrollPanel?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(bridge: (any WindowBridge)? = nil, shortcuts: any ShortcutHandling = GlobalShortcuts(),
         screens: @escaping @MainActor () -> [NSScreen] = { NSScreen.screens },
         displayProvider: (@MainActor () -> [DisplayInfo])? = nil,
         scrollInput: (any GlobalScrollHandling)? = nil, store: (any SessionPersisting)? = nil,
         preferences: UserDefaults? = .standard,
         pointerProvider: (@MainActor () -> CGPoint)? = nil,
         motionTime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         motionClockFactory: (@MainActor (String?, @escaping () -> Void) -> any FrameClockDriving)? = nil) {
        self.bridge = bridge ?? AccessibilityBridge()
        self.shortcuts = shortcuts; self.screens = screens
        self.displayProvider = displayProvider ?? { DisplayInfo.current(screens()) }
        self.pointerProvider = pointerProvider ?? {
            Self.accessibilityPoint(from: NSEvent.mouseLocation, primaryTop: screens().first?.frame.maxY ?? 0)
        }
        self.motionTime = motionTime
        self.motionClockFactory = motionClockFactory ?? { FrameClock(displayID: $0, $1) }
        self.scrollInput = scrollInput ?? GlobalScroll(); self.store = store ?? SessionStore()
        self.preferences = preferences
        if let data = preferences?.data(forKey: Self.motionSettingsKey),
           let saved = try? JSONDecoder().decode(RibbonMotionSettings.self, from: data) {
            motionSettings = saved.normalized()
        }
        self.scrollInput.updateMotionSettings(motionSettings)
        shortcuts.onAction = { [weak self] action in
            MainActor.assumeIsolated {
                if action != .pause { self?.activateDisplayForKeyboard() }
                self?.perform(action)
            }
        }
        self.scrollInput.onBegin = { [weak self] point in
            guard let self else { return }
            self.gestureDisplayID = self.displays.first(where: { $0.frame.contains(point) })?.id
            if let id = self.gestureDisplayID { self.selectDisplay(id) }
            self.beginHorizontalScroll()
        }
        self.scrollInput.onScroll = { [weak self] delta, point in
            guard let self, self.mode == .live else { return }
            if self.gestureDisplayID == nil {
                self.gestureDisplayID = self.displays.first(where: { $0.frame.contains(point) })?.id
            }
            if let id = self.gestureDisplayID { self.selectDisplay(id) }
            self.scrollHorizontally(by: delta)
        }
        self.scrollInput.onFinish = { [weak self] _ in
            self?.finishHorizontalScroll(); self?.gestureDisplayID = nil
        }
        self.scrollInput.onCompletion = { [weak self] completion, _ in
            self?.gestureCompletion = completion
        }
        self.scrollInput.onFailure = { [weak self] in
            self?.pauseAndRestore(reason: "The system stopped the scroll listener.")
        }
        observe(NSWorkspace.activeSpaceDidChangeNotification, in: NSWorkspace.shared.notificationCenter,
                reason: "Desktop changed. Restore the saved arrangement before starting another ribbon.",
                interruptsRestoration: false)
        observe(NSWorkspace.willSleepNotification, in: NSWorkspace.shared.notificationCenter,
                reason: "Mac is sleeping. Review the original desktop before restoring.")
        observe(NSApplication.didChangeScreenParametersNotification, in: .default,
                reason: "Display configuration changed. Return to the saved display arrangement before restoring.")
    }

    func resetMotionSettings() { motionSettings = RibbonMotionSettings() }

    private func observe(_ name: Notification.Name, in center: NotificationCenter, reason: String,
                         interruptsRestoration: Bool = true) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.mode == .live {
                    if name == NSWorkspace.activeSpaceDidChangeNotification {
                        // Invalidate before the system's Space animation ends.
                        // The delayed discovery must never leave old-Space
                        // motion queued against the newly visible desktop.
                        self.cancelPendingLayout(); self.scrollInput.stop(); self.preparing = true
                        self.scheduleDesktopRefresh(force: true); return
                    }
                    self.suspend(reason)
                }
                else if interruptsRestoration, self.restoreTask != nil {
                    self.restoreTask?.cancel(); self.restoreTask = nil
                    self.message = reason + " Saved originals remain on disk."
                    self.statusChanged?()
                }
            }
        })
    }

    var controlsEnabled: Bool { mode == .demo || (mode == .live && !preparing && !overviewWasActive && !bridge.desktopOverviewActive) }
    private var exclusions: Set<String> {
        Set(excludedBundleIDs.components(separatedBy: CharacterSet(charactersIn: ",\n ")).filter { !$0.isEmpty })
    }

    /// Called on launch. A pending recovery snapshot is never overwritten or
    /// automatically applied to another desktop. New sessions save before writes.
    func launch() {
        do {
            if let saved = try store.load(), !saved.pending.isEmpty {
                snapshot = saved; touched = saved.pending; pendingRestoreCount = touched.count
                capturedDisplays = saved.displays; displays = saved.displays; unchanged = saved.unchanged
                mode = .paused
                message = "A saved arrangement has \(touched.count) pending windows. Connect its displays, then Restore Saved Arrangement before starting a new session."
            } else { reviewLiveSession() }
        } catch { message = "Could not read the saved arrangement: \(error.localizedDescription). No windows moved." }
        statusChanged?()
    }

    func startDemo() {
        guard touched.isEmpty, mode != .live else { return }
        cancelPendingLayout(); scrollPanel?.orderOut(nil)
        records.removeAll(); lastApplied.removeAll(); displayStrips.removeAll(); desktopStrips.removeAll(); visibleColumns.removeAll()
        constrainedHeights.removeAll(); learnedMinimumWidths.removeAll(); constraintAttempts.removeAll()
        displays = []; activeDisplayID = nil
        viewport = Frame(x: 0, y: 0, width: 1440, height: 900)
        state = StripState(items: [
            StripItem(id: "ideas", title: "A little room to think", appName: "Notebook", width: StripState.halfScreenWidth(in: viewport)),
            StripItem(id: "build", title: "Make something useful", appName: "Workshop", width: StripState.halfScreenWidth(in: viewport)),
            StripItem(id: "read", title: "Follow your curiosity", appName: "Reading room", width: StripState.halfScreenWidth(in: viewport)),
            StripItem(id: "plan", title: "An open afternoon", appName: "Planner", width: StripState.halfScreenWidth(in: viewport)),
            StripItem(id: "music", title: "Quiet company", appName: "Player", width: 300, isFloating: true)
        ], edgeInset: 0, layoutMode: .halfScreen)
        mode = .demo; message = "Demo shapes stay inside this window. Other apps are unchanged."
        relayout()
    }

    func reviewLiveSession() {
        guard mode != .live, touched.isEmpty, restoreTask == nil else {
            message = "Restore the saved arrangement before starting another session."; return
        }
        do {
            if let saved = try store.load(), !saved.pending.isEmpty {
                launch(); return
            }
            let connected = displayProvider()
            guard !connected.isEmpty, connected.allSatisfy({ $0.usable.height > 240 }) else {
                throw WindowControlError.message("No usable desktop display is available.")
            }
            let discovered = try bridge.discover(in: connected[0].usable, excluding: exclusions)
            unchanged = bridge.inventory
            if discovered.isEmpty {
                try store.save(SessionSnapshot(displays: connected, windows: [], unchanged: unchanged))
                message = "Arrangement saved. No eligible visible windows; \(unchanged.count) entries left unchanged."
                return
            }
            try beginLiveSession(discovered, using: connected)
        } catch { message = error.localizedDescription }
        statusChanged?()
    }

    // Kept for the standalone desktop runner and the optional on-screen bar.
    func beginLiveSession(_ discovered: [ManagedWindow], on screen: NSScreen) throws {
        try beginLiveSession(discovered, using: displayProvider())
    }

    func beginLiveSession(_ discovered: [ManagedWindow], using connected: [DisplayInfo]) throws {
        guard mode != .live, touched.isEmpty, !discovered.isEmpty,
              Set(discovered.map(\.id)).count == discovered.count,
              !connected.isEmpty, topologyMatches(connected), bridge.isTrusted() else {
            throw WindowControlError.message("Window, display, or permission conditions changed. No windows moved.")
        }
        if let existing = try store.load(), !existing.pending.isEmpty {
            throw WindowControlError.message("An unrestored arrangement is already saved. Restore it first.")
        }
        let now = bridge.availableWindows()
        guard discovered.allSatisfy({ item in
            now.contains { $0.pid == item.pid && $0.number == item.number && $0.frame.approximatelyEquals(item.original) }
                && bridge.eligible(item)
        }) else { throw WindowControlError.message("The window set changed. No windows moved.") }
        let desktops = try bridge.currentDesktops(connected)
        cancelPendingLayout()
        do {
            try shortcuts.register()
            try scrollInput.start()
            let saved = SessionSnapshot(displays: connected, windows: discovered, unchanged: unchanged)
            try store.save(saved) // Durable originals before the first AX write.
            snapshot = saved
        } catch { shortcuts.unregister(); scrollInput.stop(); throw error }
        capturedDisplays = connected; displays = connected
        currentDesktops = desktops
        visibleColumns.removeAll()
        lastDiscoverySignature = bridge.discoverySignature(excluding: exclusions)
        desktopStrips.removeAll()
        constrainedHeights.removeAll(); learnedMinimumWidths.removeAll(); constraintAttempts.removeAll()
        records = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        touched = Set(discovered.map(\.id)); pendingRestoreCount = touched.count
        configureStrips(discovered)
        mayRestoreAutomatically = true; mode = .live; preparing = true
        relayout(focus: false)
        message = "Saved original frames. Arranging \(discovered.count) windows on their existing desktops…"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSession() }
        }
        statusChanged?()
    }

    private func desktopKey(_ displayID: String) -> String {
        "\(displayID):\(currentDesktops[displayID] ?? 0)"
    }
    private func cacheDesktopStrips() {
        if let active = activeDisplayID { displayStrips[active] = state }
        for (display, strip) in displayStrips { desktopStrips[desktopKey(display)] = strip }
    }
    private func configureStrips(_ windows: [ManagedWindow]) {
        let previousDisplay = activeDisplayID
        displayStrips = Dictionary(uniqueKeysWithValues: displays.map { display in
            let owned = windows.filter { DisplayInfo.owner(of: $0.original, among: displays)?.id == display.id }
            let items = owned.map { window in
                StripItem(id: window.id, title: window.title, appName: window.appName,
                          width: max(StripState.halfScreenWidth(in: display.usable),
                                     max(bridge.minimumWidth(of: window), learnedMinimumWidths[window.id] ?? 0)))
            }
            var strip = desktopStrips[desktopKey(display.id)] ?? StripState(items: items,
                focusedID: owned.first(where: \.isLocal)?.id, edgeInset: 0, layoutMode: .halfScreen)
            strip.reconcile(items)
            return (display.id, strip)
        })
        activeDisplayID = nil
        let preferred = displays.first { $0.id == previousDisplay && displayStrips[$0.id]?.items.isEmpty == false }
            ?? displays.first { displayStrips[$0.id]?.items.isEmpty == false } ?? displays.first
        if let preferred { selectDisplay(preferred.id) }
    }

    private func scheduleDesktopRefresh(force: Bool = false) {
        desktopRefreshTask?.cancel()
        desktopRefreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.refreshActiveDesktopIfNeeded(force: force)
        }
    }

    /// Native Spaces keep their own strips. Capture each desktop only when it
    /// is visited, preserving its logical offset/order and every original frame.
    func refreshActiveDesktopIfNeeded(force: Bool = false) {
        guard mode == .live, !bridge.desktopOverviewActive else { return }
        overviewWasActive = false
        do {
            let next = try bridge.currentDesktops(displays)
            guard force || next != currentDesktops else { return }
            cacheDesktopStrips()
            cancelPendingLayout(); scrollInput.stop(); preparing = true
            let generation = commitGeneration
            layoutTask = Task { [weak self] in
                guard let self else { return }
                do {
                    await self.bridge.drainMotion(); try Task.checkCancellation()
                    guard self.mode == .live, generation == self.commitGeneration else { return }
                    let discovered = try self.bridge.discover(in: self.displays[0].usable, excluding: self.exclusions)
                    guard try self.bridge.currentDesktops(self.displays) == next else {
                        self.preparing = false; self.scheduleDesktopRefresh(); return
                    }
                    let known = Dictionary(uniqueKeysWithValues: self.records.values.map { ("\($0.pid):\($0.number)", $0) })
                    let current = discovered.map { known["\($0.pid):\($0.number)"] ?? $0 }
                    let additions = current.filter { self.records[$0.id] == nil }
                    if var saved = self.snapshot, !additions.isEmpty {
                        saved.windows += additions.map(SavedWindow.init)
                        saved.pending.formUnion(additions.map(\.id))
                        try self.store.save(saved) // Append originals before moving any new window.
                        self.snapshot = saved; self.touched = saved.pending
                        self.pendingRestoreCount = self.touched.count
                    }
                    for window in additions { self.records[window.id] = window }
                    self.currentDesktops = next; self.unchanged = self.bridge.inventory
                    self.visibleColumns.removeAll()
                    self.lastDiscoverySignature = self.bridge.discoverySignature(excluding: self.exclusions)
                    self.configureStrips(current)
                    try self.scrollInput.start()
                    self.relayout(focus: false, revealFocused: false)
                } catch is CancellationError { }
                catch { self.failAndRestore(error) }
            }
        } catch { failAndRestore(error) }
    }

    func selectDisplay(_ id: String) {
        guard id != activeDisplayID, let display = displays.first(where: { $0.id == id }) else { return }
        if let old = activeDisplayID { displayStrips[old] = state }
        stopMotion()
        if activeDisplayID != nil, mode == .live {
            intentRevision &+= 1; layoutTask?.cancel(); applyingLayout = false
            commitScheduled = false; isPanning = false
        }
        activeDisplayID = id; state = displayStrips[id] ?? StripState(edgeInset: 0, layoutMode: .halfScreen)
        viewport = display.usable
        var preview = state
        placements = physicalLayout(&preview, on: display, reveal: false)
    }

    static func accessibilityPoint(from point: CGPoint, primaryTop: CGFloat) -> CGPoint {
        // Every display shares the primary display's coordinate transform,
        // including monitors above it and monitors with negative X origins.
        CGPoint(x: point.x, y: primaryTop - point.y)
    }

    private func activateDisplayForKeyboard() {
        if let focused = bridge.focusedWindowIdentity(),
           let window = records.values.first(where: { $0.pid == focused.pid && $0.number == focused.number }),
           let display = displays.first(where: { displayStrips[$0.id]?.tiledItems.contains { $0.id == window.id } == true }) {
            selectDisplay(display.id); return
        }
        if let active = activeDisplayID, displayStrips[active]?.tiledItems.isEmpty == false { return }
        let point = pointerProvider()
        if let display = displays.first(where: { $0.frame.contains(point) && displayStrips[$0.id]?.tiledItems.isEmpty == false })
            ?? displays.first(where: { displayStrips[$0.id]?.tiledItems.isEmpty == false }) {
            selectDisplay(display.id)
        }
    }

    func perform(_ action: DeskAction) {
        if action == .pause { pauseAndRestore(); return }
        guard controlsEnabled else { return }
        cancelInputGesture()
        isPanning = false; gestureDisplayID = nil
        switch action {
        case .focusLeft: state.stepFocus(-1)
        case .focusRight: state.stepFocus(1)
        case .moveLeft: state.reorderFocused(-1)
        case .moveRight: state.reorderFocused(1)
        case .narrow: setColumnWidth(0.5)
        case .medium: setColumnWidth(0.5)
        case .wide: setColumnWidth(1)
        case .full: setColumnWidth(1)
        case .first: if let id = state.tiledItems.first?.id { state.focus(id) }
        case .last: if let id = state.tiledItems.last?.id { state.focus(id) }
        case .cycleWidth:
            let half = StripState.halfScreenWidth(in: viewport, edgeInset: state.edgeInset)
            setColumnWidth((state.focusedItem?.width ?? half) > half + 0.5 ? 0.5 : 1)
        case .jump1, .jump2, .jump3, .jump4, .jump5, .jump6, .jump7, .jump8, .jump9:
            let index = Int(action.rawValue - DeskAction.jump1.rawValue)
            if state.tiledItems.indices.contains(index) { state.focus(state.tiledItems[index].id) }
        case .float: if let id = state.focusedID { toggleFloating(id); return }
        case .pause: break
        }
        scheduleLayout(focus: true)
    }

    private func setColumnWidth(_ fraction: Double) {
        let minimum = state.focusedID.flatMap { records[$0] }.map {
            max(bridge.minimumWidth(of: $0), learnedMinimumWidths[$0.id] ?? 0)
        } ?? 240
        state.setWidth(fraction: fraction, viewport: viewport, minimumWidth: minimum)
    }

    func select(_ id: String) {
        guard controlsEnabled else { return }
        cancelInputGesture(); gestureDisplayID = nil
        isPanning = false; state.focus(id); scheduleLayout(focus: true)
    }

    private func cancelInputGesture() {
        inputCancellationRevision &+= 1
        gestureStartOffset = nil; gestureCompletion = nil; pendingPointerFocus = false
        gestureFinished = false
        scrollInput.cancelGesture()
    }

    /// A contact interrupts an old settle before its first movement arrives.
    func beginHorizontalScroll() {
        guard controlsEnabled else { return }
        if snapAnimation != nil {
            snapAnimation = nil
        }
        if let presentedOffset { _ = state.scroll(by: presentedOffset - state.scrollOffset, in: viewport) }
        gestureStartOffset = state.scrollOffset; gestureCompletion = nil; pendingPointerFocus = false
        gestureFinished = false
        cancelMotionBatch()
        RuntimeDiagnostics.shared.record("gesture-began", ["offset": state.scrollOffset])
        intentRevision &+= 1; layoutTask?.cancel(); applyingLayout = false; commitScheduled = false
    }

    func scrollHorizontally(by delta: Double) {
        guard !interruptForOverviewIfNeeded() else { return }
        guard controlsEnabled else { return }
        let previous = state.scrollOffset
        guard state.scroll(by: delta, in: viewport) else { return }
        gestureFinished = false
        if !isPanning {
            if gestureStartOffset == nil { gestureStartOffset = previous; gestureCompletion = nil }
            presentedOffset = previous
        }
        snapAnimation = nil; pendingSnapTarget = nil; isPanning = true
        motionClock?.stop(); motionClock = nil
        RuntimeDiagnostics.shared.record("intent", ["delta": delta, "offset": state.scrollOffset])
        if mode == .demo { presentedOffset = state.scrollOffset; relayout(revealFocused: false); return }
        intentRevision &+= 1; layoutTask?.cancel(); applyingLayout = false
        commitScheduled = false
        queueMotionCommit()
    }

    private func interruptForOverviewIfNeeded() -> Bool {
        guard mode == .live, bridge.desktopOverviewActive else { return false }
        overviewWasActive = true; cancelInputGesture(); isPanning = false; stopMotion(); return true
    }

    /// Input wakes one main-runloop commit. New samples replace intent while a
    /// native barrier is busy; no clock, interpolation chase, or frame backlog
    /// is needed for direct movement or the coast samples generated upstream.
    private func queueMotionCommit() {
        guard mode == .live, isPanning, snapAnimation == nil, pendingSnapTarget == nil else { return }
        motionFramePending = true
        guard motionTask == nil, !motionCommitQueued else { return }
        motionCommitQueued = true
        let token = motionToken, generation = commitGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.motionToken, generation == self.commitGeneration,
                  self.motionCommitQueued else { return }
            self.motionCommitQueued = false
            guard self.mode == .live, self.isPanning, self.snapAnimation == nil,
                  self.pendingSnapTarget == nil, !self.interruptForOverviewIfNeeded() else { return }
            guard self.motionTask == nil else { return }
            self.motionFramePending = false; self.flushMotion()
        }
    }

    private func startMotionClock() {
        guard motionClock == nil else { return }
        let clock = motionClockFactory(activeDisplayID) { [weak self] in self?.advanceMotion() }
        motionClock = clock; clock.start()
    }
    private func advanceMotion() {
        guard !interruptForOverviewIfNeeded() else { return }
        if motionTask != nil {
            motionFramePending = true; busyMotionTicks += 1
            return
        }
        if let (animation, began) = snapAnimation {
            let elapsed = motionTime() - began
            _ = state.scroll(by: animation.position(after: elapsed) - state.scrollOffset, in: viewport)
            intentRevision &+= 1
            if mode == .demo { relayout(revealFocused: false) }
            if elapsed >= animation.duration {
                snapAnimation = nil; isPanning = false
                RuntimeDiagnostics.shared.record("snap-ended", ["offset": state.scrollOffset])
                if mode == .demo { state.focusNearestToCenter(in: viewport); stopMotion(); relayout(revealFocused: false) }
                else { scheduleLayout(focus: true, revealFocused: false, pointerFocus: true) }
                return
            }
        }
        flushMotion()
        if snapAnimation == nil, motionTask == nil,
           abs((presentedOffset ?? state.scrollOffset) - state.scrollOffset) < 0.05 {
            if let committedMotionPlacements { publishMotionPreview(committedMotionPlacements, force: true) }
            motionClock?.stop(); motionClock = nil
        }
    }
    func finishHorizontalScroll(completion: RibbonSwipeCompletion? = nil) {
        guard controlsEnabled, isPanning, !gestureFinished else { return }
        gestureFinished = true
        let target = state.gestureSnapOffset(in: viewport, startingAt: gestureStartOffset ?? state.scrollOffset,
                                             completion: completion ?? gestureCompletion)
        gestureStartOffset = nil; gestureCompletion = nil
        motionFramePending = false; motionCommitQueued = false
        if motionTask != nil {
            // The current frame may already be visible in a faster app. Start
            // settlement after its shared barrier, using that common position;
            // rewinding to an older completed frame would visibly bounce back.
            pendingSnapTarget = target
            return
        }
        beginSettlement(to: target)
    }

    private func beginSettlement(to target: Double) {
        pendingSnapTarget = nil
        // Start after any in-flight frame completes, using its common native
        // position instead of an uncommitted input target or an older frame.
        if let presentedOffset { _ = state.scroll(by: presentedOffset - state.scrollOffset, in: viewport) }
        RuntimeDiagnostics.shared.record("snap-start", ["from": state.scrollOffset, "to": target])
        if abs(target - state.scrollOffset) < 0.5 {
            _ = state.scroll(by: target - state.scrollOffset, in: viewport)
            isPanning = false
            if mode == .demo { state.focusNearestToCenter(in: viewport); stopMotion(); relayout(revealFocused: false) }
            else { scheduleLayout(focus: true, revealFocused: false, pointerFocus: true) }
        } else {
            snapAnimation = (StripSnap(start: state.scrollOffset, target: target), motionTime())
            startMotionClock()
        }
    }

    func showLiveScrollBar() {
        guard mode == .live, let screen = screens().first else { return }
        if scrollPanel == nil { scrollPanel = LiveScrollPanel(screen: screen, desk: self) }
        scrollPanel?.orderFront(nil)
    }

    func toggleFloating(_ id: String) {
        guard controlsEnabled, let item = state.items.first(where: { $0.id == id }) else { return }
        cancelInputGesture(); gestureDisplayID = nil
        isPanning = false
        if mode == .live, !item.isFloating, let window = records[id] {
            cancelPendingLayout(); applyingLayout = true
            let generation = commitGeneration
            layoutTask = Task { [weak self] in
                guard let self else { return }
                do {
                    await self.bridge.drainMotion(); try Task.checkCancellation()
                    guard self.sessionIsSafe(), self.isVisible(window) else { throw WindowControlError.message("Window unavailable.") }
                    try await self.performWithFreshElement(of: window) { try await self.bridge.setFrame(window.original, of: $0) }
                    guard self.mode == .live, self.commitGeneration == generation else { return }
                    self.lastApplied.removeValue(forKey: id)
                    self.state.toggleFloating(id); self.applyingLayout = false
                    self.scheduleLayout(focus: true)
                } catch is CancellationError { }
                catch { self.failAndRestore(error) }
            }
            return
        }
        state.toggleFloating(id); scheduleLayout(focus: true)
    }

    private func stopMotion() {
        motionClock?.stop(); motionClock = nil; snapAnimation = nil
        presentedOffset = nil; committedMotionPlacements = nil; pendingSnapTarget = nil
        cancelMotionBatch()
    }

    private func cancelMotionBatch() {
        // Cancellation can interrupt a provider after some native writes.
        // Unknown geometry must not masquerade as a last confirmed frame.
        if !motionInFlightIDs.isEmpty {
            for id in motionInFlightIDs { lastApplied.removeValue(forKey: id) }
            if let activeDisplayID { visibleColumns.removeValue(forKey: activeDisplayID) }
        }
        motionToken &+= 1; motionTask?.cancel(); motionTask = nil
        motionInFlightIDs.removeAll(); motionFramePending = false; motionCommitQueued = false
        pendingSnapTarget = nil; busyMotionTicks = 0
    }
    private func scheduleLayout(focus: Bool, revealFocused: Bool = true, pointerFocus: Bool = false) {
        stopMotion()
        guard mode == .live else { relayout(focus: focus, revealFocused: revealFocused); return }
        intentRevision &+= 1; layoutTask?.cancel()
        pendingFocus = focus; pendingRevealFocused = revealFocused; pendingPointerFocus = pointerFocus
        guard !commitScheduled else { return }
        commitScheduled = true
        let generation = commitGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.commitGeneration == generation, self.mode == .live,
                  self.commitScheduled, !self.isPanning else { return }
            self.commitScheduled = false
            self.relayout(focus: self.pendingFocus, revealFocused: self.pendingRevealFocused,
                          pointerFocus: self.pendingPointerFocus)
        }
    }
    private func cancelPendingLayout() {
        cancelInputGesture()
        commitGeneration &+= 1; intentRevision &+= 1
        commitScheduled = false; applyingLayout = false; preparing = false
        layoutTask?.cancel(); layoutTask = nil; stopMotion(); motionRevision = .max
        pendingFocus = false; pendingRevealFocused = true; pendingPointerFocus = false
        isPanning = false; gestureDisplayID = nil; gestureStartOffset = nil; gestureCompletion = nil
    }

    private func physicalLayout(_ strip: inout StripState, on display: DisplayInfo, reveal: Bool) -> [Placement] {
        strip.layout(in: display.usable, revealFocused: reveal).map { original in
            var p = original
            if let height = constrainedHeights[p.id] {
                p.frame.height = min(height, p.frame.height)
            }
            if displays.contains(where: { $0.id != display.id && $0.frame.intersectionArea(p.frame) > 0 }) {
                // Public AX cannot clip a window at a display seam. Park it
                // flush inside its own display only at an occupied seam. An
                // outside edge must still follow the fingers off screen.
                let x = max(display.frame.x, min(display.frame.maxX - p.frame.width, p.frame.x))
                p.isParked = p.isParked || abs(x - p.frame.x) > 0.5; p.frame.x = x
            }
            return p
        }
    }
    private func plannedLayout(revealFocused: Bool, motionOffset: Double? = nil, publishPreview: Bool = true) -> [Placement] {
        if let active = activeDisplayID { displayStrips[active] = state }
        var all: [Placement] = []
        for display in displays {
            if motionOffset != nil, display.id != activeDisplayID { continue }
            var strip = displayStrips[display.id] ?? StripState(edgeInset: 0, layoutMode: .halfScreen)
            let filtered = display.id == activeDisplayID && motionOffset != nil
            if filtered, let motionOffset { _ = strip.scroll(by: motionOffset - strip.scrollOffset, in: display.usable) }
            let result = physicalLayout(&strip, on: display, reveal: revealFocused && display.id == activeDisplayID)
            if !filtered { displayStrips[display.id] = strip }
            all += result
            if display.id == activeDisplayID {
                if !filtered { state = strip }
                if publishPreview {
                    if placements != result { placements = result }
                    if viewport != display.usable { viewport = display.usable }
                }
            }
        }
        return all
    }
    private func relayout(focus: Bool = false, revealFocused: Bool = true, pointerFocus: Bool = false) {
        guard mode == .live else {
            placements = state.layout(in: viewport, revealFocused: revealFocused); statusChanged?(); return
        }
        guard sessionIsSafe() else { suspend("Display or permission changed."); return }
        let planned = plannedLayout(revealFocused: revealFocused)
        applyingLayout = true
        apply(planned, focus: focus, pointerFocus: pointerFocus, revision: intentRevision, generation: commitGeneration)
        statusChanged?()
    }

    private struct VisibilityChange {
        let displayID: String
        let ids: Set<String>
        let windows: [ManagedWindow]
    }

    /// AX cannot clip parked windows at a display seam. A boundary crossing
    /// changes stacking once so those parked surfaces stay behind real tiles.
    private func visibilityChanges(for planned: [Placement]) -> [VisibilityChange] {
        let plannedIDs = Set(planned.map(\.id))
        return displays.compactMap { display in
            let owned = records.values.filter { DisplayInfo.owner(of: $0.original, among: displays)?.id == display.id }
            guard owned.contains(where: { plannedIDs.contains($0.id) }) else { return nil }
            let ownedIDs = Set(owned.map(\.id))
            let visible = planned.filter {
                ownedIDs.contains($0.id) && !$0.isParked && $0.frame.intersectionArea(display.usable) > 0
            }
            let ids = Set(visible.map(\.id))
            guard visibleColumns[display.id] != ids else { return nil }
            return VisibilityChange(displayID: display.id, ids: ids,
                                    windows: visible.compactMap { records[$0.id] })
        }
    }

    private func focusAfterSettling(fallback: String?) -> String? {
        let point = pointerProvider()
        guard let display = displays.first(where: { $0.usable.contains(point) }) else { return fallback }
        var strip = display.id == activeDisplayID ? state : displayStrips[display.id] ?? StripState()
        let logical = physicalLayout(&strip, on: display, reveal: false)
        let visible = bridge.visibleWindows()
        let topmost = bridge.topWindowIdentity(at: point)
        let candidate = logical.first { placement in
            guard !placement.isParked, placement.frame.contains(point),
                  let window = records[placement.id],
                  DisplayInfo.owner(of: window.original, among: displays)?.id == display.id,
                  let actual = visible.first(where: { $0.pid == window.pid && $0.number == window.number }) else { return false }
            if let topmost, topmost.pid != window.pid || topmost.number != window.number { return false }
            return actual.frame.contains(point)
        }?.id
        let selected = candidate ?? fallback
        if let candidate {
            strip.focus(candidate); displayStrips[display.id] = strip
            if display.id == activeDisplayID { state = strip }
        }
        RuntimeDiagnostics.shared.record("pointer-focus", ["x": point.x, "y": point.y,
            "display": display.id, "selected": selected ?? "", "hit": candidate != nil])
        return selected
    }

    private func publishMotionPreview(_ planned: [Placement], force: Bool = false) {
        let now = motionTime()
        guard force || now - lastPreviewTime >= 1.0 / 15 else { return }
        lastPreviewTime = now
        if placements != planned { placements = planned }
    }

    private func flushMotion() {
        guard mode == .live, isPanning, motionTask == nil else { return }
        let planningStarted = ProcessInfo.processInfo.systemUptime
        let previous = presentedOffset ?? state.scrollOffset
        // All managed windows share one quantized strip origin. Individual AX
        // providers and local AppKit must not round fractional translations in
        // different directions and make neighboring gaps shimmer.
        let offset = state.scrollOffset.rounded()
        guard motionRevision != intentRevision || abs(offset - previous) > 0.05 else { return }
        // Topology and Space notifications cancel queued motion immediately.
        // Full native validation remains at session and settled commit boundaries;
        // the gesture path performs pure geometry without display/CG inventory.
        let planned = plannedLayout(revealFocused: false, motionOffset: offset, publishPreview: false)
        let changed = planned.filter { placement in
            guard let previous = lastApplied[placement.id] else { return true }
            return abs(previous.x - placement.frame.x) > 0.1 || abs(previous.y - placement.frame.y) > 0.1
        }
        motionRevision = intentRevision
        guard !changed.isEmpty else {
            presentedOffset = offset; committedMotionPlacements = planned
            publishMotionPreview(planned)
            return
        }
        let physicalDirection = previous - offset
        let ordered = changed.sorted { left, right in
            let leftX = lastApplied[left.id]?.x ?? left.frame.x
            let rightX = lastApplied[right.id]?.x ?? right.frame.x
            return physicalDirection > 0 ? leftX > rightX : leftX < rightX
        }
        let targets = ordered.compactMap { p in records[p.id].map { ($0, p.frame) } }
        let token = motionToken, generation = commitGeneration
        let busyTicks = busyMotionTicks; busyMotionTicks = 0; motionFramePending = false
        motionInFlightIDs = Set(changed.map(\.id))
        RuntimeDiagnostics.shared.record("render", ["offset": offset, "target": state.scrollOffset,
            "count": targets.count, "raising": 0,
            "busyTicks": busyTicks, "planMS": (ProcessInfo.processInfo.systemUptime - planningStarted) * 1000])
        motionTask = Task { [weak self] in
            guard let self else { return }
            let began = ProcessInfo.processInfo.systemUptime
            do {
                try await self.bridge.movePositions(targets, raising: [])
                try Task.checkCancellation()
                guard self.mode == .live, generation == self.commitGeneration, token == self.motionToken else { return }
                for placement in changed {
                    var previous = self.lastApplied[placement.id] ?? placement.frame
                    previous.x = placement.frame.x; previous.y = placement.frame.y
                    self.lastApplied[placement.id] = previous
                }
                // Commit presentation only after every provider has completed.
                // Reversal and replacement gestures cannot pivot from a frame
                // that was merely submitted while other windows still lagged.
                self.presentedOffset = offset; self.committedMotionPlacements = planned
                self.motionInFlightIDs.removeAll(); self.motionTask = nil
                guard !self.interruptForOverviewIfNeeded() else { return }
                self.publishMotionPreview(planned)
                RuntimeDiagnostics.shared.record("motion-completed", ["offset": offset,
                    "target": self.state.scrollOffset, "count": targets.count,
                    "ms": (ProcessInfo.processInfo.systemUptime - began) * 1000,
                    "busyTicks": self.busyMotionTicks])
                if let target = self.pendingSnapTarget {
                    self.beginSettlement(to: target)
                } else if self.motionFramePending {
                    self.motionFramePending = false
                    // One queued continuation consumes current intent, never a
                    // sequence of obsolete display ticks. Yield the main actor
                    // so input and interruption notifications keep precedence.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.mode == .live, self.isPanning,
                              generation == self.commitGeneration, token == self.motionToken,
                              self.motionTask == nil else { return }
                        if self.snapAnimation != nil { self.advanceMotion() }
                        else { self.queueMotionCommit() }
                    }
                }
            } catch is CancellationError {
                guard generation == self.commitGeneration, token == self.motionToken else { return }
                for id in self.motionInFlightIDs { self.lastApplied.removeValue(forKey: id) }
                self.motionInFlightIDs.removeAll(); self.motionTask = nil
            } catch {
                guard self.mode == .live, generation == self.commitGeneration, token == self.motionToken else { return }
                for id in self.motionInFlightIDs { self.lastApplied.removeValue(forKey: id) }
                self.motionInFlightIDs.removeAll(); self.motionTask = nil; self.failAndRestore(error)
            }
        }
    }

    private func apply(_ planned: [Placement], focus: Bool, pointerFocus: Bool, revision: UInt, generation: UInt) {
        layoutTask?.cancel()
        let focused = state.focusedID
        layoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.bridge.drainMotion(); try Task.checkCancellation()
                guard self.sessionIsSafe() else { throw WindowControlError.message("The live session changed during layout.") }
                if self.bridge.desktopOverviewActive {
                    self.overviewWasActive = true; self.applyingLayout = false; throw CancellationError()
                }
                let available = self.bridge.availableWindows()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for placement in planned {
                        group.addTask { @MainActor in
                            try Task.checkCancellation()
                            guard self.mode == .live, generation == self.commitGeneration,
                                  revision == self.intentRevision else { throw CancellationError() }
                            guard let window = self.records[placement.id] else {
                                throw WindowControlError.message("The live session changed during layout.")
                            }
                            guard let actual = available.first(where: { $0.pid == window.pid && $0.number == window.number }) else {
                                throw WindowControlError.message("\(window.appName) became unavailable during layout.")
                            }
                            if actual.frame.approximatelyEquals(placement.frame, tolerance: 0.5) {
                                self.lastApplied[window.id] = actual.frame
                                return
                            }
                            let usableWindow: ManagedWindow
                            let refreshedForEligibility: Bool
                            if self.bridge.eligible(window) { usableWindow = window; refreshedForEligibility = false }
                            else if let fresh = try await self.strictFreshWindow(window, requireActiveFocus: true) {
                                usableWindow = fresh; refreshedForEligibility = true
                            } else { throw WindowControlError.message("\(window.appName) became unavailable during layout.") }
                            if self.bridge.desktopOverviewActive {
                                self.overviewWasActive = true; throw CancellationError()
                            }
                            if refreshedForEligibility { try await self.bridge.setFrame(placement.frame, of: usableWindow) }
                            else { try await self.performWithFreshElement(of: usableWindow, requireActiveFocus: true) { try await self.bridge.setFrame(placement.frame, of: $0) } }
                            try Task.checkCancellation()
                            guard self.mode == .live, generation == self.commitGeneration,
                                  revision == self.intentRevision else { throw CancellationError() }
                            self.lastApplied[window.id] = placement.frame
                        }
                    }
                    try await group.waitForAll()
                }
                guard self.mode == .live, generation == self.commitGeneration, revision == self.intentRevision else { return }
                if self.bridge.desktopOverviewActive {
                    self.overviewWasActive = true; self.applyingLayout = false; throw CancellationError()
                }
                guard try self.bridge.currentDesktops(self.displays) == self.currentDesktops else {
                    self.applyingLayout = false; self.scheduleDesktopRefresh(); return
                }
                let visibility = self.visibilityChanges(for: planned)
                try await self.bridge.raiseVisibleWindows(visibility.flatMap(\.windows))
                try Task.checkCancellation()
                guard self.mode == .live, generation == self.commitGeneration, revision == self.intentRevision else { return }
                for change in visibility { self.visibleColumns[change.displayID] = change.ids }
                var selected = focused
                if focus, pointerFocus {
                    self.state.focusNearestToCenter(in: self.viewport)
                    if let active = self.activeDisplayID { self.displayStrips[active] = self.state }
                    selected = self.focusAfterSettling(fallback: self.state.focusedID)
                }
                if focus, let id = selected, let window = self.records[id], self.isVisible(window) {
                    var performedFocus = false
                    if self.bridge.eligible(window) {
                        try await self.performWithFreshElement(of: window, requireActiveFocus: true) { try self.bridge.focus($0) }
                        performedFocus = true
                    } else if let fresh = try await self.strictFreshWindow(window, requireActiveFocus: true) {
                        try self.bridge.focus(fresh) // Already refreshed once for this focus operation.
                        performedFocus = true
                    }
                    if performedFocus {
                        let actual = self.bridge.focusedWindowIdentity()
                        RuntimeDiagnostics.shared.record("focus-requested", ["id": id, "pid": window.pid,
                            "number": window.number, "actualPID": actual?.pid ?? 0, "actualNumber": actual?.number ?? 0,
                            "pointer": pointerFocus, "observation": "immediate"])
                    }
                }
                self.applyingLayout = false
                if self.preparing {
                    self.preparing = false
                    self.message = "Each Space and display has its own ribbon. Three-finger swipes settle into half-screen slots, then activate the window under the pointer. Original frames are saved."
                }
                self.statusChanged?()
            } catch is CancellationError { }
            catch let constraint as WindowFrameConstraint {
                guard self.mode == .live, generation == self.commitGeneration, revision == self.intentRevision else { return }
                self.resolveConstraint(constraint, focus: focus, pointerFocus: pointerFocus)
            }
            catch {
                guard self.mode == .live, generation == self.commitGeneration, revision == self.intentRevision else { return }
                self.failAndRestore(error)
            }
        }
    }

    /// A stale AX proxy can outlive the native window it refers to after an
    /// app update. Only drained settled/restore operations may resolve that
    /// exact saved PID/native number and retry once. Gesture batches never do.
    private func performWithFreshElement(of window: ManagedWindow, requireActiveFocus: Bool = false,
        operation: (ManagedWindow) async throws -> Void) async throws {
        let generation = commitGeneration, revision = intentRevision, expectedMode = mode
        do { try await operation(window) }
        catch let failure as WindowElementFailure {
            try Task.checkCancellation()
            guard failure.windowID == window.id, generation == commitGeneration,
                  revision == intentRevision, mode == expectedMode else { throw failure }
            guard let fresh = try await strictFreshWindow(window, requireActiveFocus: requireActiveFocus) else { throw failure }
            try await operation(fresh) // One bounded retry; a second failure propagates.
        }
    }

    private func strictFreshWindow(_ window: ManagedWindow, requireActiveFocus: Bool = false) async throws -> ManagedWindow? {
        let generation = commitGeneration, revision = intentRevision, expectedMode = mode
        guard let saved = snapshot?.windows.first(where: {
            $0.id == window.id && $0.pid == window.pid && $0.number == window.number && $0.original == window.original
        }), let capturedAt = snapshot?.savedAt else { return nil }
        if requireActiveFocus, try !hasActiveNativeContext(window) { return nil }
        await bridge.drainMotion(); try Task.checkCancellation()
        guard let fresh = try await bridge.refreshWindow(window, saved: saved, capturedAt: capturedAt) else { return nil }
        try Task.checkCancellation()
        guard generation == commitGeneration, revision == intentRevision, mode == expectedMode else { throw CancellationError() }
        guard fresh.id == window.id, fresh.pid == window.pid, fresh.number == window.number,
              fresh.original == window.original, fresh.originalSpaces == window.originalSpaces,
              fresh.preservesDesktop == window.preservesDesktop else { return nil }
        // A Space/display change can precede its notification. Recheck native
        // context after the drain/resolution awaits, before publishing the new
        // handle or allowing a frame/focus action to consume it.
        if requireActiveFocus, try !hasActiveNativeContext(fresh) { return nil }
        records[window.id] = fresh
        return fresh
    }

    private func hasActiveNativeContext(_ window: ManagedWindow) throws -> Bool {
        guard !bridge.desktopOverviewActive, sessionIsSafe(), try bridge.currentDesktops(displays) == currentDesktops,
              let display = DisplayInfo.owner(of: window.original, among: displays),
              displayStrips[display.id]?.tiledItems.contains(where: { $0.id == window.id }) == true,
              let actual = bridge.visibleWindows().first(where: { $0.pid == window.pid && $0.number == window.number }),
              actual.frame.intersectionArea(display.usable) > 0,
              DisplayInfo.owner(of: actual.frame, among: displays)?.id == display.id else { return false }
        return true
    }

    /// Apps do not consistently expose minimum sizes through AX. A bounded
    /// readback can promote one constrained half column without stopping others.
    private func resolveConstraint(_ constraint: WindowFrameConstraint, focus: Bool, pointerFocus: Bool) {
        guard let window = records[constraint.windowID], constraint.actual.isUsable,
              let display = DisplayInfo.owner(of: window.original, among: displays) else {
            failAndRestore(constraint); return
        }
        let attempts = constraintAttempts[window.id, default: 0]
        constraintAttempts[window.id] = attempts + 1
        var strip = display.id == activeDisplayID ? state : displayStrips[display.id] ?? StripState(edgeInset: 0, layoutMode: .halfScreen)
        let selected = strip.focusedID
        let available = display.usable.width - strip.edgeInset * 2
        var adjusted = false
        if attempts < 2, constraint.actual.width > constraint.target.width + 6,
           constraint.target.width < available - 6, constraint.actual.width <= available + 6 {
            learnedMinimumWidths[window.id] = constraint.actual.width
            strip.focus(window.id)
            strip.setWidth(fraction: 1, viewport: display.usable)
            if let selected { strip.focus(selected) }
            adjusted = true
        } else if attempts < 2, abs(constraint.actual.width - constraint.target.width) <= 6,
                  constraint.actual.height < constraint.target.height - 6, constraint.actual.height >= 100 {
            constrainedHeights[window.id] = constraint.actual.height
            adjusted = true
        }
        if adjusted {
            displayStrips[display.id] = strip
            if display.id == activeDisplayID { state = strip }
            scheduleLayout(focus: focus, revealFocused: !pointerFocus, pointerFocus: pointerFocus)
            return
        }
        // A fixed or oversized native frame cannot fit either supported slot.
        // Restore only that window and leave its saved original available.
        intentRevision &+= 1; applyingLayout = true
        let generation = commitGeneration, revision = intentRevision
        layoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.bridge.drainMotion(); try Task.checkCancellation()
                try await self.performWithFreshElement(of: window) { try await self.bridge.setFrame(window.original, of: $0) }
                guard self.mode == .live, generation == self.commitGeneration, revision == self.intentRevision else { return }
                var current = display.id == self.activeDisplayID ? self.state : self.displayStrips[display.id] ?? strip
                if current.items.first(where: { $0.id == window.id })?.isFloating == false { current.toggleFloating(window.id) }
                self.displayStrips[display.id] = current
                if display.id == self.activeDisplayID { self.state = current }
                self.lastApplied.removeValue(forKey: window.id)
                self.preparing = false
                self.message = "\(window.appName) cannot fit a ribbon slot. Its original frame was restored; the other windows remain in the ribbon."
                self.scheduleLayout(focus: focus, revealFocused: !pointerFocus, pointerFocus: pointerFocus)
            } catch is CancellationError { }
            catch { self.failAndRestore(error) }
        }
    }

    func pauseAndRestore(reason: String? = nil) {
        RuntimeDiagnostics.shared.record("pause", ["pending": touched.count])
        desktopRefreshTask?.cancel(); desktopRefreshTask = nil
        cancelPendingLayout(); scrollInput.stop(); scrollPanel?.orderOut(nil)
        timer?.invalidate(); timer = nil; shortcuts.unregister()
        let wasDemo = mode == .demo; mode = .paused
        restoreReason = reason.map { $0 + " " } ?? ""
        if wasDemo { message = "Demo paused. Other apps were unchanged." }
        else if mayRestoreAutomatically { restoreVisible() }
        else { message = "Paused. Connect the saved displays, then Restore Saved Arrangement." }
        statusChanged?()
    }

    func confirmRestore() {
        guard !touched.isEmpty, mode != .live else { return }
        restoreVisible()
    }

    private func persistPending() throws {
        guard var saved = snapshot else { return }
        saved.pending = touched
        if touched.isEmpty { saved.restoredAt = Date() }
        try store.save(saved); snapshot = saved
    }

    private func restoreVisible() {
        restoreTask?.cancel(); restoreTask = nil
        guard !touched.isEmpty else { message = restoreReason + "Paused. No saved frames remain to restore."; return }
        guard bridge.isTrusted(), topologyMatches(capturedDisplays) else {
            message = "Restore pending: Accessibility access and the saved display arrangement are required. Originals remain on disk."; return
        }
        if let saved = snapshot {
            let available = bridge.availableWindows()
            for item in saved.windows where touched.contains(item.id) {
                let app = NSRunningApplication(processIdentifier: item.pid)
                let launchChanged: Bool
                if let original = item.launchDate, let current = app?.launchDate {
                    launchChanged = abs(current.timeIntervalSince(original)) >= 0.01
                } else { launchChanged = false }
                let startedAfterCapture = item.launchDate == nil && (ProcessIdentity.startTime(item.pid).map { $0 > (item.capturedAt ?? saved.savedAt) } ?? false)
                let windowEnded = !available.isEmpty && !available.contains { $0.pid == item.pid && $0.number == item.number }
                if app == nil || launchChanged || startedAfterCapture || windowEnded {
                    // This application instance ended. Never bind its saved
                    // geometry to a new process that reused the PID. Closed
                    // individual windows also cannot be restored; an all-Space
                    // inventory distinguishes them from inactive desktops.
                    touched.remove(item.id); records.removeValue(forKey: item.id)
                }
            }
            for window in bridge.recover(saved.windows.filter { touched.contains($0.id) && records[$0.id] == nil }, capturedAt: saved.savedAt) {
                records[window.id] = window
            }
        }
        message = restoreReason + "Paused. Restoring \(touched.count) saved frame(s)…"
        let ids = touched.sorted()
        restoreTask = Task { [weak self] in
            guard let self else { return }
            await self.bridge.drainMotion()
            var failures: [String] = []
            for id in ids {
                guard !Task.isCancelled else { return }
                guard let window = self.records[id] else { failures.append("Unavailable window remains saved"); continue }
                if NSRunningApplication(processIdentifier: window.pid)?.isTerminated != false {
                    self.touched.remove(id); self.lastApplied.removeValue(forKey: id)
                    continue
                }
                guard self.isAvailable(window), self.topologyMatches(self.capturedDisplays) else { failures.append("\(window.appName): unavailable"); continue }
                do {
                    try await self.performWithFreshElement(of: window) { try await self.bridge.restoreWindow($0) }
                    try Task.checkCancellation()
                    self.touched.remove(id); self.lastApplied.removeValue(forKey: id)
                    try self.persistPending()
                } catch is CancellationError { return }
                catch { failures.append(error.localizedDescription) }
                self.pendingRestoreCount = self.touched.count
            }
            guard !Task.isCancelled else { return }
            do { try self.persistPending() } catch { failures.append("Could not update the recovery file: \(error.localizedDescription)") }
            self.restoreTask = nil; self.pendingRestoreCount = self.touched.count
            self.message = self.restoreReason + (self.touched.isEmpty && failures.isEmpty
                ? "Paused. All surviving captured windows were restored; no shortcuts or scroll tap remain registered."
                : "Paused. \(self.touched.count) restore(s) pending. \(failures.prefix(2).joined(separator: "; "))")
            self.statusChanged?()
        }
    }

    private func suspend(_ reason: String) {
        desktopRefreshTask?.cancel(); desktopRefreshTask = nil
        cancelPendingLayout(); scrollInput.stop(); scrollPanel?.orderOut(nil)
        timer?.invalidate(); timer = nil; shortcuts.unregister()
        mode = .paused; mayRestoreAutomatically = false
        message = reason + " Control is off; original frames remain saved on disk."
        statusChanged?()
    }
    private func failAndRestore(_ error: Error) { pauseAndRestore(reason: error.localizedDescription) }
    private func topologyMatches(_ saved: [DisplayInfo]) -> Bool {
        let now = displayProvider()
        return now.count == saved.count && saved.allSatisfy { old in
            now.contains { $0.id == old.id && $0.frame == old.frame && $0.usable == old.usable }
        }
    }
    private func sessionIsSafe() -> Bool { mode == .live && bridge.isTrusted() && topologyMatches(capturedDisplays) }
    private func isVisible(_ window: ManagedWindow) -> Bool {
        bridge.visibleWindows().contains { $0.pid == window.pid && $0.number == window.number }
    }
    private func isAvailable(_ window: ManagedWindow) -> Bool {
        bridge.availableWindows().contains { $0.pid == window.pid && $0.number == window.number }
    }
    func checkSession() {
        guard mode == .live else { return }
        if bridge.desktopOverviewActive { overviewWasActive = true; return }
        if overviewWasActive { refreshActiveDesktopIfNeeded(force: true); return }
        guard !preparing else { return }
        guard !isPanning, !commitScheduled, !applyingLayout else { return }
        if (try? bridge.currentDesktops(displays)) != currentDesktops {
            refreshActiveDesktopIfNeeded(); return
        }
        guard sessionIsSafe() else { suspend("Display or permission changed."); return }
        if bridge.discoverySignature(excluding: exclusions) != lastDiscoverySignature {
            refreshActiveDesktopIfNeeded(force: true); return
        }
        let visible = bridge.visibleWindows()
        for strip in displayStrips.values {
            for item in strip.tiledItems {
                guard let window = records[item.id],
                      let actual = visible.first(where: { $0.pid == window.pid && $0.number == window.number }) else {
                    refreshActiveDesktopIfNeeded(force: true); return
                }
                if lastApplied[item.id]?.approximatelyEquals(actual.frame, tolerance: 8) != true,
                   !bridge.eligible(window) {
                    suspend("A managed window is no longer eligible. Its saved frame remains available for recovery."); return
                }
                // A manual move or late target-app animation does not disable
                // the entire desktop. Cache actual geometry without writing;
                // the next explicit strip action will reconcile that window.
                lastApplied[item.id] = actual.frame
            }
        }
    }

    func prepareToQuit() -> Bool {
        if mode == .live { pauseAndRestore() }
        if restoreTask != nil {
            message = "Restoration is still running. Quit again after the saved frames finish restoring."
            statusChanged?(); return false
        }
        guard !touched.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "\(touched.count) saved frames remain pending"
        alert.informativeText = "The recovery file will remain on disk. Return to the saved desktop and displays to retry. Quitting will not discard the saved originals."
        alert.addButton(withTitle: "Cancel Quit"); alert.addButton(withTitle: "Quit and Keep Snapshot")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
