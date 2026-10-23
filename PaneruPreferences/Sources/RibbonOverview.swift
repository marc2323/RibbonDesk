import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RibbonOverviewModel: ObservableObject {
    @Published var windows: [RibbonWindow] = []
    @Published var previews: [Int32: RibbonPreviewFrame] = [:]
    @Published var overviewOffset = 0.0
    @Published var zoomedOut = false
    @Published var transitioning = false
    @Published var exitTargetID: Int32?
    var animatesTransitions = false
    var viewportX = 0.0
    var viewportY = 0.0
    var backdrop: NSImage?
    @Published var selectedID: Int32?
    @Published var draggingID: Int32?
    @Published var insertion: (id: Int32, after: Bool)?
    @Published var message = ""
    @Published var previewPermission = CGPreflightScreenCaptureAccess()
    @Published var moving = false
    @Published var windowActionPending = false
    var jump: ((Int32) -> Void)?
    var move: ((Int32, Int32, Bool) -> Void)?
    var close: (() -> Void)?
    var refreshPreviews: (() -> Void)?
    var pan: ((Double) -> Void)?
    var revealSelection: (() -> Void)?
    var dragChanged: (() -> Void)?
    var pointerEntered: ((Int32) -> Void)?
    var windowAction: ((Int32, RibbonWindowAction) -> Void)?
    var selected: RibbonWindow? { windows.first { $0.id == selectedID } ?? windows.first }
    func select(_ delta: Int) {
        guard !windows.isEmpty else { return }
        let current = windows.firstIndex { $0.id == selectedID } ?? 0
        selectedID = windows[min(windows.count - 1, max(0, current + delta))].id
        revealSelection?()
    }
}

private final class RibbonPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RibbonOverviewController {
    let model = RibbonOverviewModel()
    var canShow: () -> Bool = { true }
    var willShow: (() -> Void)?
    var animateTransitions: () -> Bool = { false }
    private var panel: RibbonPanel?
    private var snapshot: RibbonSnapshot?
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var outsideMonitor: Any?
    private var subscription: Process?
    private var subscriptionPipe: Pipe?
    private var refreshTask: Task<Void, Never>?
    private var endingTask: Task<Void, Never>?
    private var openingTask: Task<Void, Never>?
    private var handoffTask: Task<Void, Never>?
    private var handoffTimeout: Task<Void, Never>?
    private var handoff: RibbonHandoffGate?
    private var reorderQueue = RibbonReorderQueue()
    private var keyboardPointerAnchor: NSPoint?
    private var pendingEnterID: Int32?
    private var windowActionTask: Task<Void, Never>?
    private var dragScrollTimer: Timer?
    private var opening = false
    private var generation = UUID()
    private var originalApp: NSRunningApplication?
    private let previews = RibbonPreviewCapture()
    private var cachedBackdrop: (url: URL, image: NSImage)?

    var isVisible: Bool { panel != nil }

    init() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init("local.paneru.overview.show"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.show() }
        })
        observers.append(center.addObserver(forName: .init("local.paneru.overview.close"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.handoff != nil { self.close(restoreFocus: false) } else { self.dismiss() }
            }
        })
        observers.append(center.addObserver(forName: .init("local.paneru.overview.ready"), object: nil, queue: .main) { [weak self] notification in
            guard let value = notification.object as? String, let id = Int32(value) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.handoff?.acknowledge(id)
                self.revealIfReady()
            }
        })
        observers.append(center.addObserver(forName: .init("local.paneru.overview.accept"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.enterFromPointer() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close(restoreFocus: false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        })
        model.close = { [weak self] in self?.dismiss() }
        model.jump = { [weak self] id in self?.jump(to: id) }
        model.move = { [weak self] id, target, after in self?.move(id, beside: target, after: after) }
        model.refreshPreviews = { [weak self] in self?.capturePreviews(requestPermission: true) }
        model.pan = { [weak self] offset in self?.pan(to: offset) }
        model.revealSelection = { [weak self] in self?.revealSelection() }
        model.dragChanged = { [weak self] in self?.updateDragScroll() }
        model.pointerEntered = { [weak self] id in self?.updatePointerSelection(enteredID: id) }
        model.windowAction = { [weak self] id, action in self?.performWindowAction(action, on: id) }
    }

    nonisolated private static func readSnapshot() throws -> RibbonSnapshot {
        let text = try Engine.run(["query", "state", "--json"])
        return try JSONDecoder().decode(RibbonSnapshot.self, from: Data(text.utf8))
    }

    func show() {
        guard !isVisible, !opening, canShow() else { return }
        opening = true
        let token = UUID()
        generation = token
        originalApp = NSWorkspace.shared.frontmostApplication
        let previous = openingTask
        let ending = endingTask
        openingTask = Task {
            var began = false
            defer { if token == generation { openingTask = nil } }
            do {
                await previous?.value
                await ending?.value
                guard token == generation else { return }
                guard canShow() else { opening = false; return }
                try await Task.detached { _ = try Engine.run(["send-cmd", "overview", "begin", String(getpid())]) }.value
                began = true
                let value = try await Task.detached { try Self.readSnapshot() }.value
                guard token == generation, canShow(), !value.ribbon.isEmpty else {
                    _ = try? await Task.detached { try Engine.run(["send-cmd", "overview", "end"]) }.value
                    if token == generation { opening = false }
                    return
                }
                snapshot = value
                model.windows = value.ribbon
                model.selectedID = value.ribbon.first(where: \.focused)?.id ?? value.ribbon.first?.id
                model.previews = previews.begin(windows: value.ribbon)
                model.animatesTransitions = animateTransitions() && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                model.zoomedOut = !model.animatesTransitions
                model.transitioning = false
                model.exitTargetID = nil
                model.message = ""
                model.moving = false
                model.windowActionPending = false
                willShow?()
                present(on: value.active.display_id)
                opening = false
                capturePreviews()
                subscribe()
            } catch {
                if began { _ = try? await Task.detached { try Engine.run(["send-cmd", "overview", "end"]) }.value }
                if token == generation { opening = false }
                NSLog("Ribbon Overview: %@", error.localizedDescription)
            }
        }
    }

    private func present(on displayID: UInt32?) {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.main ?? NSScreen.screens[0]
        // Stay below the menu bar, without changing presentation/auto-hide settings.
        let menuHeight = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        let panelFrame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width,
                                height: screen.frame.height - menuHeight)
        let window = RibbonPanel(contentRect: panelFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = true
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.title = "Ribbon Overview"
        window.contentView = NSHostingView(rootView: RibbonOverviewView(model: model))
        window.setFrame(panelFrame, display: true)
        let displayBounds = displayID.map(CGDisplayBounds) ?? CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
        let anchor = model.windows.first { window in
            guard let frame = window.frame else { return false }
            let overlap = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height).intersection(displayBounds)
            return !overlap.isNull && overlap.width > min(40, frame.width * 0.15)
        }
        if let native = anchor?.frame, let ribbon = anchor?.ribbon_frame {
            model.viewportX = ribbon.x - (native.x + (native.width - ribbon.width) / 2 - displayBounds.minX)
            model.viewportY = ribbon.y - (native.y + (native.height - ribbon.height) / 2 - displayBounds.minY - menuHeight)
        } else { model.viewportX = 0; model.viewportY = 0 }
        let camera = RibbonCamera(windows: model.windows)
        model.overviewOffset = camera.initialOffset(camera.overview(width: panelFrame.width, height: panelFrame.height),
                                                    viewportX: model.viewportX, width: panelFrame.width)
        if let url = NSWorkspace.shared.desktopImageURL(for: screen) {
            if cachedBackdrop?.url != url, let image = NSImage(contentsOf: url) { cachedBackdrop = (url, image) }
            model.backdrop = cachedBackdrop?.image
        }
        panel = window
        window.makeKeyAndOrderFront(nil)
        updatePointerSelection()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp, .scrollWheel, .mouseMoved]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.type == .mouseMoved {
                self.updatePointerSelection()
                return event
            }
            if event.type == .scrollWheel {
                // AppKit may leave window nil on trackpad/momentum packets for
                // a nonactivating panel. This local monitor only sees our app.
                if !self.model.transitioning {
                    let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                    self.pan(to: self.model.overviewOffset - delta * (event.hasPreciseScrollingDeltas ? 1 : 24))
                }
                return nil
            }
            if event.type == .leftMouseUp {
                DispatchQueue.main.async { self.model.draggingID = nil; self.model.insertion = nil }
                return event
            }
            guard !self.model.transitioning else { return nil }
            let commandModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if commandModifiers == .command, let id = self.model.selected?.id {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "w": if !event.isARepeat { self.performWindowAction(.close, on: id) }; return nil
                case "q": if !event.isARepeat { self.performWindowAction(.quitApp, on: id) }; return nil
                default: break
                }
            }
            if self.model.windowActionPending {
                if event.keyCode == 53 { self.dismiss() }
                return nil
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .shift, .numericPad, .function])
            if modifiers.isEmpty || modifiers == [.control, .option] {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "j": self.reorderSelected(-1); return nil
                case "k": self.reorderSelected(1); return nil
                default: break
                }
            }
            switch event.keyCode {
            case 53: self.dismiss()
            case 123: self.keyboardPointerAnchor = NSEvent.mouseLocation; self.model.select(-1)
            case 124: self.keyboardPointerAnchor = NSEvent.mouseLocation; self.model.select(1)
            case 36, 76: if let id = self.model.selected?.id { self.jump(to: id) }
            default: return event
            }
            return nil
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close(restoreFocus: false)
        }
    }

    private func dismiss() {
        if opening && !isVisible { close(); return }
        guard isVisible, !model.transitioning else { return }
        guard model.animatesTransitions else { close(); return }
        model.transitioning = true
        model.exitTargetID = nil
        withAnimation(.easeOut(duration: 0.16)) { model.zoomedOut = false }
        let token = generation
        Task {
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard token == generation else { return }
            close()
        }
    }

    func close(restoreFocus: Bool = true) {
        guard panel != nil || opening else { return }
        generation = UUID()
        opening = false
        handoff = nil
        reorderQueue.clear()
        keyboardPointerAnchor = nil
        pendingEnterID = nil
        windowActionTask?.cancel(); windowActionTask = nil
        model.windowActionPending = false
        handoffTask?.cancel(); handoffTask = nil
        handoffTimeout?.cancel(); handoffTimeout = nil
        previews.stop()
        dragScrollTimer?.invalidate(); dragScrollTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        subscriptionPipe?.fileHandleForReading.readabilityHandler = nil
        subscription?.terminationHandler = nil
        if subscription?.isRunning == true { subscription?.terminate() }
        subscription = nil
        subscriptionPipe = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        eventMonitor = nil
        outsideMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        snapshot = nil
        model.previews = [:]
        model.backdrop = nil
        model.draggingID = nil
        model.insertion = nil
        endingTask = Task.detached { _ = try? Engine.run(["send-cmd", "overview", "end"]) }
        if restoreFocus { originalApp?.activate(options: []) }
        originalApp = nil
    }

    private func jump(to id: Int32, allowingModal: Bool = false) {
        guard !model.moving, !model.transitioning, !model.windowActionPending, model.windows.contains(where: { $0.id == id }) else { return }
        model.transitioning = true
        model.exitTargetID = id
        let token = generation
        previews.stop()
        handoff = RibbonHandoffGate(targetID: id, animationFinished: !model.animatesTransitions)
        if model.animatesTransitions {
            withAnimation(.easeOut(duration: 0.16)) { model.zoomedOut = false }
        }
        handoffTask = Task {
            do {
                guard token == generation else { return }
                try await Task.detached { _ = try Engine.run(["send-cmd", "overview", "focus", String(id)]) }.value
                if model.animatesTransitions { try await Task.sleep(nanoseconds: 160_000_000) }
                guard token == generation, !Task.isCancelled else { return }
                handoff?.animationFinished = true
                revealIfReady()
            } catch {
                if token == generation, !Task.isCancelled { handoffFailed() }
            }
        }
        handoffTimeout = Task {
            try? await Task.sleep(nanoseconds: allowingModal ? 350_000_000 : 1_000_000_000)
            guard token == generation, !Task.isCancelled, handoff != nil else { return }
            // Save/quit dialogs can own native focus instead of the parent
            // window. Uncover that app even when its parent cannot acknowledge
            // the ordinary exact-window handoff. Click/swipe entry still uses
            // the strict readiness gate and its normal failure behavior.
            if allowingModal { close(restoreFocus: false) } else { handoffFailed() }
        }
    }

    private func revealIfReady() {
        if handoff?.canReveal == true { close(restoreFocus: false) }
    }

    private func handoffFailed() {
        handoff = nil
        handoffTask?.cancel(); handoffTimeout?.cancel()
        model.zoomedOut = true
        model.transitioning = false
        model.exitTargetID = nil
        model.message = "Couldn’t activate that window. Try selecting it again."
        model.previews = previews.begin(windows: model.windows)
        capturePreviews()
    }

    private func move(_ id: Int32, beside target: Int32, after: Bool, follow: Bool = false) {
        guard !model.moving, !model.transitioning, !model.windowActionPending, isVisible, id != target else { return }
        model.moving = true
        model.message = "Moving window…"
        let token = generation
        Task {
            do {
                _ = try await Task.detached {
                    try Engine.run(["send-cmd", "overview", "move", String(id), String(target), after ? "after" : "before"])
                }.value
                // Commands and queries use the same ordered IPC event queue.
                let value = try await Task.detached { try Self.readSnapshot() }.value
                guard token == generation else { return }
                apply(value)
                if follow, model.selectedID == id { revealSelection() }
                model.message = "Order updated"
            } catch {
                guard token == generation else { return }
                model.message = "Couldn’t move the window. " + error.localizedDescription
                reorderQueue.clear()
            }
            model.moving = false
            processReorders()
        }
    }

    private func reorderSelected(_ delta: Int) {
        guard !model.transitioning, !model.windowActionPending, pendingEnterID == nil, model.draggingID == nil, let id = model.selected?.id else { return }
        keyboardPointerAnchor = NSEvent.mouseLocation
        reorderQueue.append(id: id, delta: delta)
        processReorders()
    }

    private func processReorders() {
        guard isVisible, !model.moving, !model.transitioning, !model.windowActionPending else { return }
        if let next = reorderQueue.next(windows: model.windows) {
            move(next.id, beside: next.target, after: next.after, follow: true)
        } else if let id = pendingEnterID {
            pendingEnterID = nil
            jump(to: id)
        }
    }

    private func windowUnderPointer() -> Int32? {
        guard let panel else { return nil }
        let point = panel.mouseLocationOutsideOfEventStream
        return RibbonCamera(windows: model.windows).windowAt(x: point.x, y: panel.frame.height - point.y,
            width: panel.frame.width, height: panel.frame.height, offset: model.overviewOffset)
    }

    private func updatePointerSelection(enteredID: Int32? = nil) {
        guard !model.transitioning, !model.windowActionPending, model.draggingID == nil, NSEvent.pressedMouseButtons == 0 else { return }
        if let anchor = keyboardPointerAnchor {
            let point = NSEvent.mouseLocation
            if abs(point.x - anchor.x) < 2 && abs(point.y - anchor.y) < 2 { return }
            keyboardPointerAnchor = nil
        }
        if let id = enteredID ?? windowUnderPointer() { model.selectedID = id }
    }

    private func enterFromPointer() {
        if opening && !isVisible { close(); return }
        guard isVisible, !model.transitioning, !model.windowActionPending else { return }
        guard let id = windowUnderPointer() ?? model.selected?.id else { dismiss(); return }
        model.selectedID = id
        reorderQueue.clear()
        if model.moving { pendingEnterID = id } else { jump(to: id) }
    }

    private func apply(_ value: RibbonSnapshot) {
        guard let snapshot, snapshot.sharesWorkspace(with: value), !value.ribbon.isEmpty else { close(restoreFocus: false); return }
        guard !model.transitioning, value.ribbon != model.windows else { return }
        self.snapshot = value
        let newIDs = Set(value.ribbon.map(\.id)).subtracting(model.windows.map(\.id))
        let selection = ribbonSelection(after: value.ribbon, previous: model.windows, selectedID: model.selectedID)
        model.windows = value.ribbon
        model.selectedID = selection
        let validIDs = Set(value.ribbon.map(\.id))
        model.previews = model.previews.filter { validIDs.contains($0.key) }
        for window in value.ribbon where newIDs.contains(window.id) { model.previews[window.id] = previews.frame(for: window) }
        pan(to: model.overviewOffset)
    }

    private func performWindowAction(_ action: RibbonWindowAction, on id: Int32) {
        guard isVisible, !model.moving, !model.transitioning, !model.windowActionPending,
              model.draggingID == nil, model.windows.contains(where: { $0.id == id }) else { return }
        model.selectedID = id
        keyboardPointerAnchor = NSEvent.mouseLocation
        reorderQueue.clear()
        pendingEnterID = nil
        model.windowActionPending = true
        model.message = action == .close ? "Closing window…" : "Quitting app…"
        let token = generation
        windowActionTask = Task {
            defer { if token == generation { windowActionTask = nil } }
            do {
                _ = try await Task.detached {
                    try Engine.run(["send-cmd", "overview", action.rawValue, String(id)])
                }.value
                // Native destruction arrives asynchronously. Keep the overview
                // while it completes, but uncover save sheets/confirmation UI
                // if the original window remains. Never force-close or retry.
                try await Task.sleep(nanoseconds: 650_000_000)
                let value = try await Task.detached { try Self.readSnapshot() }.value
                guard token == generation, !Task.isCancelled else { return }
                apply(value)
                guard token == generation else { return }
                model.windowActionPending = false
                if value.ribbon.contains(where: { $0.id == id }) { jump(to: id, allowingModal: true) }
                else {
                    model.message = action == .close ? "Window closed" : "Quit requested"
                    revealSelection()
                }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                model.windowActionPending = false
                model.message = "Couldn’t send the request. " + error.localizedDescription
            }
        }
    }

    private func subscribe() {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: Engine.binary)
        process.arguments = ["subscribe", "--json"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let token = generation
        let changes = RibbonOverviewChanges()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, changes.consume(data) else { return }
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                guard self.refreshTask == nil, !self.model.transitioning else { return }
                self.refreshTask = Task {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    guard !Task.isCancelled else { return }
                    defer { if self.generation == token { self.refreshTask = nil } }
                    do {
                        let value = try await Task.detached { try Self.readSnapshot() }.value
                        guard self.generation == token else { return }
                        self.apply(value)
                    } catch { self.close(restoreFocus: false) }
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.close(restoreFocus: false)
            }
        }
        do { try process.run(); subscription = process; subscriptionPipe = pipe }
        catch { model.message = "Live updates unavailable. Reopen the overview to refresh." }
    }

    private func capturePreviews(requestPermission: Bool = false) {
        model.previewPermission = CGPreflightScreenCaptureAccess()
        if !model.previewPermission, requestPermission {
            model.previewPermission = CGRequestScreenCaptureAccess()
            if !model.previewPermission {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                return
            }
        }
        guard model.previewPermission else { return }
        let token = generation
        guard let panel, !model.transitioning else { return }
        let width = panel.frame.width
        let backing = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let camera = RibbonCamera(windows: model.windows)
        let overview = camera.overview(width: width, height: panel.frame.height)
        let visible = camera.visibleIDs(scale: overview.scale, x: overview.x - model.overviewOffset, width: width)
        let targets = model.windows.filter { visible.contains($0.id) }.sorted { $0.id == model.selectedID && $1.id != model.selectedID }
        previews.request(windows: targets, frames: model.previews, scale: overview.scale, backingScale: backing) { [weak self] error in
            guard let self, self.generation == token else { return }
            self.model.message = error
        }
    }

    private func pan(to offset: Double) {
        guard let panel, !model.transitioning else { return }
        let overview = RibbonCamera(windows: model.windows).overview(width: panel.frame.width, height: panel.frame.height)
        model.overviewOffset = overview.clamped(offset)
        capturePreviews()
        updatePointerSelection()
    }

    private func revealSelection() {
        guard let panel, let id = model.selectedID else { return }
        let camera = RibbonCamera(windows: model.windows)
        let overview = camera.overview(width: panel.frame.width, height: panel.frame.height)
        guard let frame = camera.placements.first(where: { $0.id == id })?.frame else { return }
        let left = frame.x * overview.scale + overview.x - model.overviewOffset
        let right = left + frame.width * overview.scale
        if left < 48 { pan(to: model.overviewOffset + left - 48) }
        else if right > panel.frame.width - 48 { pan(to: model.overviewOffset + min(left - 48, right - panel.frame.width + 48)) }
    }

    private func updateDragScroll() {
        dragScrollTimer?.invalidate(); dragScrollTimer = nil
        guard model.draggingID != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, self.model.draggingID != nil,
                      NSEvent.pressedMouseButtons & 1 != 0 else {
                    self?.model.draggingID = nil; self?.updateDragScroll(); return
                }
                let point = panel.mouseLocationOutsideOfEventStream
                guard point.y >= 0, point.y <= panel.frame.height, point.x >= 0, point.x <= panel.frame.width else { return }
                if point.x < 60 { self.pan(to: self.model.overviewOffset - Double(60 - point.x) * 0.3) }
                else if point.x > panel.frame.width - 60 { self.pan(to: self.model.overviewOffset + Double(point.x - panel.frame.width + 60) * 0.3) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragScrollTimer = timer
    }
}

struct RibbonOverviewView: View {
    @ObservedObject var model: RibbonOverviewModel
    private let accent = Color(red: 0.32, green: 0.77, blue: 0.87)
    var body: some View {
        GeometryReader { geometry in
            let camera = RibbonCamera(windows: model.windows)
            let overview = camera.overview(width: geometry.size.width, height: geometry.size.height)
            let scale = model.zoomedOut ? overview.scale : 1
            let overviewX = overview.x - overview.clamped(model.overviewOffset)
            let destinationX = -camera.destination(id: model.exitTargetID, viewportX: model.viewportX, width: geometry.size.width)
            let originX = model.zoomedOut ? overviewX : destinationX
            let originY = model.zoomedOut ? overview.y : -model.viewportY
            let visible = camera.visibleIDs(scale: overview.scale, x: overviewX, width: geometry.size.width)
                .union(camera.visibleIDs(scale: 1, x: destinationX, width: geometry.size.width))
            ZStack(alignment: .topLeading) {
                backdrop
                Color.black.opacity(model.zoomedOut ? 0.32 : 0).ignoresSafeArea()
                    .contentShape(Rectangle()).onTapGesture { model.close?() }
                // Keep window layout fixed; animate a single scene transform.
                ZStack(alignment: .topLeading) {
                    ForEach(Array(model.windows.enumerated()).filter { visible.contains($0.element.id) }, id: \.element.id) { index, window in
                        let placement = camera.placements[index].frame
                        windowSurface(window, index: index)
                            .zIndex(window.focused ? Double(model.windows.count + 2) : Double(model.windows.count - index + 1))
                            .frame(width: placement.width, height: placement.height)
                            .position(x: placement.x + placement.width / 2, y: placement.y + placement.height / 2)
                    }
                }.frame(width: 1, height: 1, alignment: .topLeading)
                 .scaleEffect(scale, anchor: .topLeading).offset(x: originX, y: originY)
                VStack {
                    HStack {
                        if !model.previewPermission {
                            Label("Allow Screen Recording to see window previews", systemImage: "rectangle.on.rectangle")
                            Button("Allow Window Previews…") { model.refreshPreviews?() }.buttonStyle(.bordered)
                        } else {
                            Text(model.message.isEmpty ? "Click or swipe down to enter · J/K to arrange · Scroll to browse" : model.message)
                        }
                        Spacer(minLength: 12)
                        Button { model.close?() } label: { Image(systemName: "xmark").padding(8) }
                            .buttonStyle(.plain).help("Close overview (Escape)")
                    }
                    Spacer()
                    if let selected = model.selected {
                        Text(selected.app_name + " · " + selected.label).lineLimit(1)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.black.opacity(0.7), in: Capsule())
                            .opacity(model.zoomedOut ? 1 : 0)
                        HStack(spacing: 16) {
                            Button("Close Window  ⌘W") { model.windowAction?(selected.id, .close) }
                                .help("Close the highlighted window")
                            Button("Quit \(selected.app_name)  ⌘Q") { model.windowAction?(selected.id, .quitApp) }
                                .help("Quit this app, including its other windows")
                        }.buttonStyle(RibbonActionButtonStyle()).lineLimit(1)
                         .disabled(model.moving || model.windowActionPending)
                         .opacity(model.zoomedOut ? 1 : 0)
                    }
                    if overview.maxOffset > 0 {
                        HStack(spacing: 12) {
                            Button { model.pan?(model.overviewOffset - geometry.size.width * 0.7) } label: { Image(systemName: "chevron.left") }
                            RibbonScrollTrack(offset: model.overviewOffset, maximum: overview.maxOffset,
                                              visibleWidth: overview.availableWidth, pan: { model.pan?($0) })
                            Button { model.pan?(model.overviewOffset + geometry.size.width * 0.7) } label: { Image(systemName: "chevron.right") }
                        }.buttonStyle(.plain).frame(width: min(360, geometry.size.width - 80))
                         .opacity(model.zoomedOut ? 1 : 0)
                    }
                }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).padding(20)
                 .zIndex(Double(model.windows.count + 10))
            }.clipped()
             .allowsHitTesting(!model.transitioning)
             .onChange(of: model.draggingID) { _ in model.dragChanged?() }
             .onAppear {
                 DispatchQueue.main.async {
                     guard !model.transitioning, model.animatesTransitions else { return }
                     withAnimation(.easeOut(duration: 0.16)) { model.zoomedOut = true }
                 }
             }
        }.preferredColorScheme(.dark)
    }

    @ViewBuilder private var backdrop: some View {
        if let image = model.backdrop {
            GeometryReader { geometry in
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }.ignoresSafeArea()
        } else { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() }
    }

    private func windowSurface(_ window: RibbonWindow, index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        return ZStack {
            if let frame = model.previews[window.id] {
                SnapshotWindowSurface(frame: frame, label: window.label, appName: window.app_name)
            } else { Color.black.opacity(0.2) }
        }
        .clipShape(shape)
        .overlay(shape.stroke(model.selectedID == window.id ? accent.opacity(0.9) : .white.opacity(0.12), lineWidth: model.selectedID == window.id ? 2 : 0.5))
        .overlay(alignment: model.insertion?.after == true ? .trailing : .leading) {
            if model.insertion?.id == window.id { Capsule().fill(accent).frame(width: 3).padding(.vertical, -5) }
        }
        .opacity(model.draggingID == window.id ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.jump?(window.id) }
        .onHover {
            if $0 && NSEvent.pressedMouseButtons == 0 { model.draggingID = nil; model.insertion = nil }
            if $0 && model.draggingID == nil { model.pointerEntered?(window.id) }
        }
        .onDrag {
            guard !model.moving, !model.windowActionPending else { return NSItemProvider() }
            model.draggingID = window.id
            return NSItemProvider(object: String(window.id) as NSString)
        }
        .onDrop(of: [UTType.utf8PlainText], delegate: RibbonDropDelegate(model: model, target: window.id,
            width: (window.ribbon_frame ?? window.frame)?.width ?? 900))
        .contextMenu {
            Button("Close Window") { model.windowAction?(window.id, .close) }
            Button("Quit \(window.app_name)") { model.windowAction?(window.id, .quitApp) }
        }
        .help(window.app_name + " — " + window.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(index + 1). \(window.app_name), \(window.label)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.jump?(window.id) }
        .accessibilityAction(named: "Move left") { if index > 0 { model.move?(window.id, model.windows[index - 1].id, false) } }
        .accessibilityAction(named: "Move right") { if index + 1 < model.windows.count { model.move?(window.id, model.windows[index + 1].id, true) } }
        .accessibilityAction(named: "Close Window") { model.windowAction?(window.id, .close) }
        .accessibilityAction(named: "Quit App") { model.windowAction?(window.id, .quitApp) }
    }
}

private struct RibbonActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 12).padding(.vertical, 7)
            .background(.black.opacity(configuration.isPressed ? 0.8 : 0.6), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.2), lineWidth: 0.5))
            .contentShape(Rectangle())
    }
}

private struct RibbonScrollTrack: View {
    let offset: Double
    let maximum: Double
    let visibleWidth: Double
    let pan: (Double) -> Void
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumb = min(width, max(32, width * visibleWidth / (maximum + visibleWidth)))
            let progress = min(1, max(0, offset / maximum))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15)).frame(height: 4)
                Capsule().fill(.white.opacity(0.7)).frame(width: thumb, height: 5)
                    .offset(x: (width - thumb) * progress)
            }.frame(height: 22).contentShape(Rectangle())
             .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                 pan(maximum * min(1, max(0, (value.location.x - thumb / 2) / max(1, width - thumb))))
             })
        }.frame(height: 22)
         .accessibilityElement(children: .ignore).accessibilityLabel("Ribbon position")
         .accessibilityValue("\(Int(100 * min(1, max(0, offset / maximum)))) percent")
         .accessibilityAdjustableAction { direction in
             pan(min(maximum, max(0, offset + (direction == .increment ? visibleWidth * 0.7 : -visibleWidth * 0.7))))
         }
    }
}

private struct SnapshotWindowSurface: View {
    @ObservedObject var frame: RibbonPreviewFrame
    let label: String
    let appName: String
    var body: some View {
        if let image = frame.image {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
        } else {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                VStack(spacing: 6) {
                    Text(appName).font(.system(size: 13, weight: .medium))
                    Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }.padding(8)
            }
        }
    }
}

private struct RibbonDropDelegate: DropDelegate {
    let model: RibbonOverviewModel
    let target: Int32
    let width: Double
    func validateDrop(info: DropInfo) -> Bool { model.draggingID != nil && !model.moving && !model.transitioning && !model.windowActionPending }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if model.draggingID != target { model.insertion = (target, info.location.x > width / 2) }
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { if model.insertion?.id == target { model.insertion = nil } }
    func performDrop(info: DropInfo) -> Bool {
        guard let source = model.draggingID else { return false }
        model.draggingID = nil
        model.insertion = nil
        guard source != target else { return true }
        model.move?(source, target, info.location.x > width / 2)
        return true
    }
}
