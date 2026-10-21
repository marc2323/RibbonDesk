import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let desk = DeskController()
    private var statusItem: NSStatusItem!
    private var dashboard: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "RibbonDesk") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else { statusItem.button?.title = "RD" }
        statusItem.button?.toolTip = "RibbonDesk — disabled"
        desk.statusChanged = { [weak self] in self?.refreshMenu() }
        buildMainMenu()
        refreshMenu()
        // Save durable originals before arranging this desktop. Recovery from
        // an interrupted session takes priority over creating another snapshot.
        openDashboard()
        // Ensure the dashboard has its WindowServer identity before capture.
        DispatchQueue.main.async {
            let arguments = ProcessInfo.processInfo.arguments
            let preview = Bundle.main.bundleIdentifier == "local.prototype.RibbonDesk.preview"
            if arguments.contains("--demo") || (preview && !arguments.contains("--live")) { self.desk.startDemo() }
            else { self.desk.launch() }
        }
    }

    private func item(_ title: String, action: Selector, key: String = "", tag: Int = 0) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self; entry.tag = tag
        return entry
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let root = NSMenuItem(); main.addItem(root)
        let app = NSMenu(); root.submenu = app
        app.addItem(item("Open RibbonDesk…", action: #selector(openDashboard)))
        app.addItem(.separator())
        app.addItem(item("Quit RibbonDesk", action: #selector(quit), key: "q"))
        let actionRoot = NSMenuItem(title: "Strip", action: nil, keyEquivalent: "")
        let actions = NSMenu(title: "Strip")
        actions.autoenablesItems = false
        for binding in ShortcutBindings.menu { actions.addItem(shortcutItem(binding)) }
        let jump = NSMenuItem(title: "Focus Window", action: nil, keyEquivalent: "")
        let jumpMenu = NSMenu(title: "Focus Window")
        jumpMenu.autoenablesItems = false
        for binding in ShortcutBindings.jumps { jumpMenu.addItem(shortcutItem(binding)) }
        jump.submenu = jumpMenu; actions.addItem(jump)
        actionRoot.submenu = actions; main.addItem(actionRoot)
        NSApp.mainMenu = main
    }

    private func shortcutItem(_ binding: ShortcutBinding) -> NSMenuItem {
        // Live Carbon hotkeys are the sole keyboard dispatch path. Giving the
        // same menu an active equivalent can execute a cycle twice when this
        // app is frontmost. In the isolated demo, AppKit owns the equivalents.
        let live = desk.mode == .live
        let title = live ? "\(binding.title)    \(binding.display)" : binding.title
        let entry = item(title, action: #selector(command(_:)),
                         key: live ? "" : binding.keyEquivalent, tag: Int(binding.action.rawValue))
        entry.keyEquivalentModifierMask = binding.modifierMask
        entry.isEnabled = desk.controlsEnabled
        return entry
    }

    func refreshMenu() {
        buildMainMenu()
        let menu = NSMenu(); menu.autoenablesItems = false
        let status = NSMenuItem(title: "RibbonDesk · \(desk.mode.rawValue)", action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status)
        menu.addItem(item("Open RibbonDesk…", action: #selector(openDashboard)))
        menu.addItem(.separator())
        let demo = item("Try Isolated Demo", action: #selector(demo))
        demo.isEnabled = desk.mode != .live && desk.pendingRestoreCount == 0; menu.addItem(demo)
        let live = item("Save & Arrange Windows", action: #selector(liveSession))
        live.isEnabled = desk.mode != .live && desk.pendingRestoreCount == 0; menu.addItem(live)
        let scrollBar = item("Show Live Scroll Bar", action: #selector(showScrollBar))
        scrollBar.isEnabled = desk.mode == .live; menu.addItem(scrollBar)
        menu.addItem(.separator())
        for binding in ShortcutBindings.menu { menu.addItem(shortcutItem(binding)) }
        if desk.mode == .live {
            let keyboard = NSMenuItem(title: desk.shortcutDiagnostics.summary, action: nil, keyEquivalent: "")
            keyboard.isEnabled = false; menu.addItem(keyboard)
            if !desk.shortcutWarnings.isEmpty {
                let warnings = NSMenuItem(title: "\(desk.shortcutWarnings.count) unavailable shortcuts…", action: nil, keyEquivalent: "")
                let details = NSMenu()
                for warning in desk.shortcutWarnings {
                    let entry = NSMenuItem(title: warning, action: nil, keyEquivalent: "")
                    entry.isEnabled = false; details.addItem(entry)
                }
                warnings.submenu = details; menu.addItem(warnings)
            }
        }
        if desk.pendingRestoreCount > 0 {
            let restore = item("Restore Saved Arrangement (\(desk.pendingRestoreCount))", action: #selector(restoreFrames))
            restore.isEnabled = desk.mode != .live; menu.addItem(restore)
        }
        menu.addItem(.separator())
        let recording = RuntimeDiagnostics.shared.isCapturing
        menu.addItem(item(recording ? "Stop Motion Diagnostics" : "Record Motion Diagnostics (60 seconds)",
                          action: #selector(toggleDiagnostics)))
        menu.addItem(item("Quit RibbonDesk", action: #selector(quit)))
        statusItem.menu = menu
        statusItem.button?.toolTip = "RibbonDesk — \(desk.mode.rawValue)"
    }

    @objc func openDashboard() {
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "RibbonDesk"
            window.identifier = NSUserInterfaceItemIdentifier("RibbonDesk.dashboard")
            window.delegate = self
            window.contentMinSize = NSSize(width: 600, height: 460)
            if let screen = NSScreen.main {
                let usable = screen.visibleFrame
                window.setContentSize(NSSize(width: min(900, usable.width), height: min(700, usable.height - 28)))
            }
            window.contentView = NSHostingView(rootView: DashboardView(desk: desk))
            window.isReleasedWhenClosed = false; window.center()
            dashboard = window
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboard?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard()
        return false
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Restore while the enrolled dashboard still exists. A second close
        // after restoration closes it normally without losing its saved frame.
        if desk.mode == .live { desk.pauseAndRestore(); return false }
        return desk.pendingRestoreCount == 0
    }
    @objc private func demo() { desk.startDemo(); openDashboard() }
    @objc private func liveSession() { openDashboard(); desk.reviewLiveSession() }
    @objc private func showScrollBar() { desk.showLiveScrollBar() }
    @objc private func restoreFrames() { desk.confirmRestore() }
    @objc private func toggleDiagnostics() {
        if RuntimeDiagnostics.shared.isCapturing { RuntimeDiagnostics.shared.stopCapture() }
        else { RuntimeDiagnostics.shared.startCapture(seconds: 60) }
        refreshMenu()
    }
    @objc private func command(_ sender: NSMenuItem) {
        guard let action = DeskAction(rawValue: UInt32(sender.tag)) else { return }
        desk.perform(action)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        desk.prepareToQuit() ? .terminateNow : .terminateCancel
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
