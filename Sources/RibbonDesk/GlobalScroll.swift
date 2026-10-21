import AppKit
import RibbonCore

@MainActor
protocol GlobalScrollHandling: AnyObject {
    var onBegin: ((CGPoint) -> Void)? { get set }
    var onScroll: ((Double, CGPoint) -> Void)? { get set }
    var onFinish: ((CGPoint) -> Void)? { get set }
    var onCompletion: ((RibbonSwipeCompletion, CGPoint) -> Void)? { get set }
    var onFailure: (() -> Void)? { get set }
    func start() throws
    func stop()
    func cancelGesture()
    func updateMotionSettings(_ settings: RibbonMotionSettings)
}

extension GlobalScrollHandling {
    var onCompletion: ((RibbonSwipeCompletion, CGPoint) -> Void)? {
        get { nil }
        set {}
    }
    func cancelGesture() {}
    func updateMotionSettings(_ settings: RibbonMotionSettings) {}
}

private struct TouchIdentity: Hashable {
    let value: any NSObjectProtocol
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.value.isEqual(rhs.value) }
    func hash(into hasher: inout Hasher) { hasher.combine(value.hash) }
}

/// Observes actual AppKit contact identities at the HID gesture tap. Scroll-wheel
/// events are absent from the mask: two-finger scrolling and native momentum
/// retain the system's normal route. Classification never calls AX.
@MainActor
final class GlobalScroll: GlobalScrollHandling {
    var onBegin: ((CGPoint) -> Void)?
    var onScroll: ((Double, CGPoint) -> Void)?
    var onFinish: ((CGPoint) -> Void)?
    var onCompletion: ((RibbonSwipeCompletion, CGPoint) -> Void)?
    var onFailure: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = ThreeFingerSwipe(settings: .default)
    private var motionSettings = RibbonMotionSettings.default
    private var generation = 0
    private var coastClock: FrameClock?
    private var lastContactTime = 0.0
    private var idleTask: Task<Void, Never>?
    private var active = false
    private var origin = CGPoint.zero
    private var liftingContacts: [AnyHashable: CGPoint] = [:]
    private var liftTime = 0.0
    private var completion: RibbonSwipeCompletion?

    func updateMotionSettings(_ settings: RibbonMotionSettings) {
        let settings = settings.normalized()
        guard settings != motionSettings else { return }
        finish(reason: "motion-settings-changed")
        motionSettings = settings
        gesture = ThreeFingerSwipe(settings: settings)
        liftingContacts = [:]
    }

    func start() throws {
        stop()
        guard AXIsProcessTrusted(), let port = CGEvent.tapCreate(tap: .cghidEventTap,
            place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: NSEvent.EventTypeMask.gesture.rawValue | NSEvent.EventTypeMask.beginGesture.rawValue | NSEvent.EventTypeMask.endGesture.rawValue,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<GlobalScroll>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        owner.stop()
                        DispatchQueue.main.async { owner.onFailure?() }
                        return Unmanaged.passUnretained(event)
                    }
                    guard let native = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
                    return owner.route(native, at: event.location) ? nil : Unmanaged.passUnretained(event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw WindowControlError.message("Three-finger swiping needs RibbonDesk’s current Accessibility access. The gesture listener could not start; no windows were moved.")
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Also callable with in-memory events. Wheel input is never intercepted.
    func route(_ event: NSEvent, at point: CGPoint) -> Bool {
        if event.type == .beginGesture {
            if coastClock != nil { finish(reason: "new-native-gesture") }
            return false
        }
        if event.type == .endGesture {
            return route(contacts: [], at: point, time: event.timestamp, phase: .ended)
        }
        guard event.type == .gesture else { return false }
        return routeTouches(event, at: point)
    }

    @discardableResult
    func routeTouches(_ event: NSEvent, at point: CGPoint) -> Bool {
        let touches = event.allTouches()
        let contacts = touches.filter { $0.phase != .ended && $0.phase != .cancelled }.map {
            ThreeFingerSwipe.Contact(id: TouchIdentity(value: $0.identity),
                                     x: Double($0.normalizedPosition.x), y: Double($0.normalizedPosition.y))
        }
        RuntimeDiagnostics.shared.record("touch", ["phase": event.phase.rawValue, "count": contacts.count,
            "touchPhases": touches.map { $0.phase.rawValue }, "timestamp": event.timestamp,
            "horizontal": gesture.isHorizontal, "coasting": coastClock != nil])
        let cancelled = event.phase.contains(.cancelled) || touches.contains { $0.phase == .cancelled }
        let ended = event.phase.contains(.ended) || (!touches.isEmpty && contacts.isEmpty)
        if !liftingContacts.isEmpty {
            // A physical lift arrives as 3 -> 2 -> 1 -> 0 contacts on some
            // trackpads. Those remaining contacts belong to the same release;
            // do not let their end frames immediately cancel the new coast.
            let newTouch = touches.contains { $0.phase == .began }
            let moved = contacts.contains { contact in
                guard let old = liftingContacts[contact.id] else { return true }
                // Sliding fingers still move as pressure falls during a lift.
                // The old 0.004 cutoff cancelled real flicks within 8 ms.
                return hypot(contact.x - old.x, contact.y - old.y) > 0.04
            }
            if cancelled || newTouch || moved || (!contacts.isEmpty && event.timestamp - liftTime > 0.12) {
                liftingContacts = [:]; finish()
            } else {
                if contacts.isEmpty { liftingContacts = [:] }
                return false
            }
        }
        let partialLift = gesture.hasThreeFingerContact && contacts.count < 3 && touches.contains { $0.phase == .ended }
        if partialLift && !cancelled {
            liftingContacts = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
            liftTime = event.timestamp
        }
        // Include the final positions of lifted fingers. Otherwise a quick
        // swipe with only one motion sample can disappear at its release.
        let finalContacts = touches.filter { $0.phase != .cancelled }.map {
            ThreeFingerSwipe.Contact(id: TouchIdentity(value: $0.identity),
                                     x: Double($0.normalizedPosition.x), y: Double($0.normalizedPosition.y))
        }
        return route(contacts: ended || partialLift ? finalContacts : contacts, at: point, time: event.timestamp,
                     phase: cancelled ? .cancelled : ended || partialLift ? .ended : .changed)
    }

    /// Shared by the global tap, isolated demo touch surface, and fixture tests.
    @discardableResult
    func route(contacts: [ThreeFingerSwipe.Contact], at point: CGPoint, time: Double,
               phase: ThreeFingerSwipe.Phase = .changed) -> Bool {
        if !contacts.isEmpty, coastClock != nil { finish() }
        let wasHorizontal = gesture.isHorizontal
        if !contacts.isEmpty { lastContactTime = time }
        let update = gesture.consume(contacts, at: time, phase: phase)
        RuntimeDiagnostics.shared.record("input", ["count": contacts.count, "delta": update.delta,
            "velocity": update.velocity, "began": update.began, "finished": update.finished])
        if update.began {
            origin = point; active = true; completion = nil
            deliver(began: true)
        }
        if update.delta != 0 { deliver(delta: update.delta) }
        if update.finished {
            idleTask?.cancel(); idleTask = nil
            completion = update.completion
            let momentum = SwipeMomentum(velocity: update.velocity, amount: motionSettings.momentum)
            if momentum.finished { finish() }
            else { coast(momentum) }
        } else if gesture.isHorizontal {
            // Raw HID gestures do not reliably emit a final touch/end event.
            // Like Paneru, infer release from a brief quiet input interval so
            // inertia also works when no explicit lift arrives.
            idleTask?.cancel()
            idleTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 70_000_000) } catch { return }
                guard let self, !Task.isCancelled else { return }
                let release = self.gesture.consume([], at: self.lastContactTime + 0.07, phase: .ended)
                self.completion = release.completion
                RuntimeDiagnostics.shared.record("quiet-release", ["velocity": release.velocity])
                let momentum = SwipeMomentum(velocity: release.velocity, amount: self.motionSettings.momentum)
                if momentum.finished { self.finish(reason: "quiet-no-velocity") }
                else { self.coast(momentum) }
            }
        }
        return gesture.isHorizontal || update.finished || (wasHorizontal && phase != .changed)
    }

    private func coast(_ initial: SwipeMomentum) {
        idleTask?.cancel(); idleTask = nil
        coastClock?.stop()
        RuntimeDiagnostics.shared.record("coast-start", ["velocity": initial.velocity])
        var momentum = initial
        var last = ProcessInfo.processInfo.systemUptime
        // Resolve once from the gesture's fixed AX origin. A pointer move to
        // another display must not retime an already coasting ribbon.
        let displayID = DisplayInfo.current(NSScreen.screens).first { $0.frame.contains(origin) }?.id
        let clock = FrameClock(displayID: displayID) { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let delta = momentum.step(seconds: now - last); last = now
            RuntimeDiagnostics.shared.record("coast", ["delta": delta])
            if delta != 0 { self.deliver(delta: delta) }
            if momentum.finished { self.finish(reason: "coast-ended") }
        }
        coastClock = clock; clock.start()
    }

    private func finish(reason: String = "interrupted-or-ended") {
        coastClock?.stop(); coastClock = nil
        idleTask?.cancel(); idleTask = nil
        guard active else { return }
        RuntimeDiagnostics.shared.record("finish", ["reason": reason]); RuntimeDiagnostics.shared.flush()
        active = false
        deliver(finished: true, completion: completion ?? RibbonSwipeCompletion(cancelled: true))
        completion = nil
    }

    private func deliver(began: Bool = false, delta: Double? = nil, finished: Bool = false,
                         completion: RibbonSwipeCompletion? = nil) {
        let token = generation, point = origin
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            if began { self.onBegin?(point) }
            if let delta { self.onScroll?(delta, point) }
            if finished {
                if let completion { self.onCompletion?(completion, point) }
                self.onFinish?(point)
            }
        }
    }

    /// Explicit focus/reorder/width actions take precedence over all pending
    /// gesture work, while the installed listener remains ready for a new swipe.
    func cancelGesture() {
        generation &+= 1; gesture.reset(); active = false; liftingContacts = [:]; completion = nil
        coastClock?.stop(); coastClock = nil; idleTask?.cancel(); idleTask = nil
    }

    func stop() {
        cancelGesture()
        RuntimeDiagnostics.shared.flush()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
    }
}
