import AppKit
import Darwin

// Compile with the production shortcuts and diagnostics, without the AX bridge
// or desktop controller. Native key deliveries cannot move or focus windows.
enum WindowControlError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

@MainActor
final class ShortcutSmoke: NSObject, NSApplicationDelegate {
    private let shortcuts = GlobalShortcuts(bindings: ShortcutBindings.all.filter {
        $0.isPrimary && ($0.action == .focusLeft || $0.action == .focusRight || $0.action == .cycleWidth)
    })
    private var timer: Timer?
    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var countdownLabel: NSTextField?
    private var deadline = 0.0
    private var counts: [DeskAction: Int] = [:]

    private func requestedDuration() -> TimeInterval {
        let arguments = ProcessInfo.processInfo.arguments
        let bundled = Bundle.main.bundleIdentifier == "local.prototype.RibbonDesk.shortcut-check"
        let fallback: TimeInterval = bundled ? 300 : 60
        guard let index = arguments.firstIndex(of: "--seconds") else { return fallback }
        guard arguments.indices.contains(index + 1), let seconds = Double(arguments[index + 1]),
              seconds.isFinite, seconds > 0 else {
            print("ERROR --seconds requires a positive duration, capped at 300 seconds.")
            fflush(stdout); exit(2)
        }
        return min(seconds, 300)
    }

    private func refreshStatus() {
        let remaining = max(0, Int(ceil(deadline - ProcessInfo.processInfo.systemUptime)))
        countdownLabel?.stringValue = String(format: "READY · %d:%02d remaining", remaining / 60, remaining % 60)
        statusLabel?.stringValue = "\(shortcuts.diagnostics.summary)\nH: \(counts[.focusLeft, default: 0])   L: \(counts[.focusRight, default: 0])   R: \(counts[.cycleWidth, default: 0])"
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        print("DONE \(shortcuts.diagnostics.summary)"); fflush(stdout)
        shortcuts.unregister(); NSApp.terminate(nil)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        var failures = 0
        ShortcutChecks.run { success, message in
            print("\(success ? "PASS" : "FAIL") \(message)")
            if !success { failures += 1 }
        }
        fflush(stdout)
        if failures > 0 { exit(1) }
        if ProcessInfo.processInfo.arguments.contains("--unit-only") { exit(0) }
        let duration = requestedDuration()
        shortcuts.onAction = { [weak self] action in
            guard let self else { return }
            self.counts[action, default: 0] += 1
            print("NATIVE action=\(action.rawValue) \(self.shortcuts.diagnostics.summary)")
            self.refreshStatus()
            fflush(stdout)
        }
        do {
            try shortcuts.register()
            deadline = ProcessInfo.processInfo.systemUptime + duration
            print("READY duration=\(Int(duration))s native Carbon H/L/R; no AX bridge, no window mutations. \(shortcuts.diagnostics.summary)")
            fflush(stdout)
        } catch { print("FAIL \(error.localizedDescription)"); fflush(stdout); exit(1) }
        if !ProcessInfo.processInfo.arguments.contains("--no-window") {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 570, height: 220),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "RibbonDesk Keyboard Test — no desktop control"
            let countdown = NSTextField(labelWithString: "READY")
            countdown.font = .monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
            countdown.textColor = .systemGreen
            countdown.frame = NSRect(x: 20, y: 175, width: 530, height: 30)
            let heading = NSTextField(wrappingLabelWithString: "Press Control + Option + H, L, or R while another app is active.\nThis receiver counts hotkeys and never moves or focuses windows.")
            heading.frame = NSRect(x: 20, y: 100, width: 530, height: 60)
            let status = NSTextField(wrappingLabelWithString: self.shortcuts.diagnostics.summary)
            status.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            status.frame = NSRect(x: 20, y: 25, width: 530, height: 55)
            window.contentView?.addSubview(countdown)
            window.contentView?.addSubview(heading); window.contentView?.addSubview(status)
            window.isReleasedWhenClosed = false; window.orderFront(nil)
            self.window = window; self.statusLabel = status; self.countdownLabel = countdown
        }
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshStatus()
                if ProcessInfo.processInfo.systemUptime >= self.deadline { self.finish() }
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { shortcuts.unregister() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = ShortcutSmoke(); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
