import AppKit

// Disposable native windows for close/quit checks. No documents or user data.
// The protected window simulates an app that asks before closing.
final class Fixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windows: [NSWindow] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem()
        menu.addItem(item)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Ribbon Overview Test", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        NSApplication.shared.mainMenu = menu
        for title in ["Close Button Check", "Close Shortcut Check", "Context Menu Check", "Save Prompt Check"] {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = title
            window.delegate = self
            window.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: "Disposable overview test window\n" + title)
            label.alignment = .center
            label.frame = NSRect(x: 40, y: 300, width: 520, height: 60)
            window.contentView?.addSubview(label)
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.title == "Save Prompt Check" else { return true }
        if sender.attachedSheet == nil {
            let alert = NSAlert()
            alert.messageText = "Test save confirmation"
            alert.informativeText = "This is a disposable test. Cancel to keep this window."
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: sender)
        }
        return false
    }
}

let application = NSApplication.shared
let fixture = Fixture()
application.setActivationPolicy(.regular)
application.delegate = fixture
application.run()
