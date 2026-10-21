import AppKit

/// Disposable real windows for manual/CUA AX integration checks. This process
/// does not access other applications or request Accessibility permission.
@MainActor
final class InputProbe: NSView {
    private let label = NSTextField(labelWithString: "Disposable RibbonDesk window. Scroll here to inspect native event delivery.")
    private var samples: [String] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.frame = NSRect(x: 24, y: 24, width: frame.width - 48, height: 60)
        label.autoresizingMask = [.width]
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityLabel("Native scroll input probe")
        setAccessibilityValue("No scroll events received")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func scrollWheel(with event: NSEvent) {
        let value = "x=\(event.scrollingDeltaX) y=\(event.scrollingDeltaY) precise=\(event.hasPreciseScrollingDeltas) phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue)"
        label.stringValue = value
        samples.append(value)
        setAccessibilityValue(samples.suffix(16).joined(separator: "; "))
    }
}

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow] = []
    var originalFrames: [[String: Any]] = []
    var history: [[String: Any]] = []
    private var frameRecords: [[String: Any]] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return windows.map { window in
            ["title": window.title, "x": window.frame.minX, "y": top - window.frame.maxY,
             "width": window.frame.width, "height": window.frame.height, "key": window.isKeyWindow,
             "minimized": window.isMiniaturized]
        }
    }
    private func record() {
        history.append(["frames": frameRecords, "time": Date().timeIntervalSince1970])
        let snapshot: [String: Any] = ["original": originalFrames, "current": frameRecords, "history": history]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
            let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("fixture-frames.json")
            try? data.write(to: url, options: .atomic)
        }
    }
    func windowDidMove(_ notification: Notification) { record() }
    func windowDidResize(_ notification: Notification) { record() }
    func windowDidBecomeKey(_ notification: Notification) { record() }
    func windowDidMiniaturize(_ notification: Notification) { record() }
    func windowDidDeminiaturize(_ notification: Notification) { record() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        for (screenIndex, screen) in NSScreen.screens.enumerated() {
        let usable = screen.visibleFrame
        let width = floor(usable.width * 0.65)
        for index in 0..<2 {
            let x = index == 0 ? usable.minX + 24 : usable.maxX - width - 24
            let frame = NSRect(x: x, y: usable.minY + 130 + CGFloat(index * 30),
                               width: width, height: min(500, usable.height - 200))
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false, screen: screen)
            window.title = "RibbonDesk Disposable \(screenIndex + 1).\(index + 1)"
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.contentView = InputProbe(frame: NSRect(origin: .zero, size: frame.size))
            window.orderFront(nil)
            windows.append(window)
        }
        }
        // This one must be accounted for but kept unchanged by launch tiling.
        if let screen = NSScreen.screens.first {
            let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 80,
                y: screen.visibleFrame.minY + 80, width: 400, height: 300),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "RibbonDesk Disposable Minimized"
            window.isReleasedWhenClosed = false; window.delegate = self
            window.orderFront(nil); window.miniaturize(nil); windows.append(window)
        }
        originalFrames = frameRecords
        record()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.originalFrames = self.frameRecords; self.record()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let menu = NSMenu(), root = NSMenuItem(), submenu = NSMenu()
    let quit = NSMenuItem(title: "Quit Test Windows", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quit.target = app; submenu.addItem(quit); root.submenu = submenu; menu.addItem(root); app.mainMenu = menu
    let delegate = FixtureDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
