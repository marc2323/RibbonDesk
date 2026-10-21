import AppKit
import ApplicationServices

/// Observe overview transitions instead of treating Mission Control's temporary
/// thumbnail bounds as real window geometry. No UI actions or Space transfers.
@MainActor
final class DesktopActivity {
    private(set) var isActive = false
    private var observer: AXObserver?
    private var application: AXUIElement?
    private let names = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop", "AXExposeExit"]

    func start() {
        guard observer == nil, AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        var created: AXObserver?
        guard AXObserverCreate(dock.processIdentifier, { _, _, notification, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let owner = Unmanaged<DesktopActivity>.fromOpaque(context).takeUnretainedValue()
                owner.isActive = notification as String != "AXExposeExit"
            }
        }, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        for name in names {
            _ = AXObserverAddNotification(created, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        observer = created; application = app
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    deinit {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
    }
}
