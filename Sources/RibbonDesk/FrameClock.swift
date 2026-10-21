import AppKit
import CoreVideo
import QuartzCore

@MainActor
private final class DisplayTickTarget: NSObject {
    var callback: (() -> Void)?
    @objc func frame(_ sender: AnyObject) { callback?() }
}

private final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !pending else { return false }; pending = true; return true
    }
    func release() { lock.lock(); pending = false; lock.unlock() }
}

/// One main-thread update per display refresh, with at most one callback queued.
/// A slow app can delay a commit but cannot accumulate a backlog of old frames.
@MainActor
protocol FrameClockDriving: AnyObject {
    var displayID: String? { get }
    func start()
    func stop()
}

@MainActor
final class FrameClock: FrameClockDriving {
    let displayID: String?
    private let gate = FrameGate()
    private let target = DisplayTickTarget()
    private var modernLink: AnyObject?
    private var link: CVDisplayLink?
    private var fallback: Timer?
    private var running = false
    private let tick: () -> Void
    init(displayID: String? = nil, _ tick: @escaping () -> Void) {
        self.displayID = displayID
        self.tick = tick
        target.callback = { [weak self] in guard let self, self.running else { return }; self.tick() }
    }
    func start() {
        guard !running else { return }; running = true
        if #available(macOS 14, *) {
            if let screen = Self.screen(for: displayID, among: NSScreen.screens) {
                let display = screen.displayLink(target: target, selector: #selector(DisplayTickTarget.frame(_:)))
                display.add(to: .main, forMode: .common)
                modernLink = display
            } else { startFallback() }
        } else { startLegacy() }
    }

    static func screen(for displayID: String?, among screens: [NSScreen]) -> NSScreen? {
        // Pin to the ribbon being moved. Moving the cursor during a gesture
        // must not silently clock an external ribbon from another display.
        if let displayID, let matched = screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue == displayID
        }) { return matched }
        return screens.first
    }

    @available(macOS, deprecated: 15)
    private func startLegacy() {
        var created: CVDisplayLink?
        let result: CVReturn
        if let displayID, let number = UInt32(displayID) {
            result = CVDisplayLinkCreateWithCGDisplay(number, &created)
        } else { result = CVDisplayLinkCreateWithActiveCGDisplays(&created) }
        if result == kCVReturnSuccess, let created {
            let result = CVDisplayLinkSetOutputCallback(created, { _, _, _, _, _, context in
                guard let context else { return kCVReturnSuccess }
                let owner = Unmanaged<FrameClock>.fromOpaque(context).takeUnretainedValue()
                guard owner.gate.claim() else { return kCVReturnSuccess }
                DispatchQueue.main.async { [weak owner] in
                    guard let owner else { return }
                    owner.gate.release()
                    if owner.running { owner.tick() }
                }
                return kCVReturnSuccess
            }, Unmanaged.passUnretained(self).toOpaque())
            if result == kCVReturnSuccess, CVDisplayLinkStart(created) == kCVReturnSuccess { link = created; return }
        }
        startFallback()
    }
    private func startFallback() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.running else { return }; self.tick() }
        }
        fallback = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        running = false
        if #available(macOS 14, *) { (modernLink as? CADisplayLink)?.invalidate() }
        else { stopLegacy() }
        modernLink = nil
        fallback?.invalidate(); fallback = nil
    }
    @available(macOS, deprecated: 15)
    private func stopLegacy() { if let link { CVDisplayLinkStop(link) }; link = nil }
    deinit {
        if #available(macOS 14, *) { (modernLink as? CADisplayLink)?.invalidate() }
        else if let link { CVDisplayLinkStop(link) }
        fallback?.invalidate()
    }
}
