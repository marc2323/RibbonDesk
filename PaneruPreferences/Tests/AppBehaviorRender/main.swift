import AppKit
import SwiftUI

// Isolated UI/model checks. No engine, installed preferences, or visible windows.
enum Engine {
    static let binary = "/bin/false"
    static func isRunning() -> Bool { false }
    static func run(_ arguments: [String]) throws -> String { "{}" }
}
enum PreferenceFiles {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ribbon-behavior-render-\(UUID().uuidString)")
    static let script = directory.appendingPathComponent("init.lua")
    static func reload() throws {}
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)
    let store = AppBehaviorStore(directory: PreferenceFiles.directory)
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let model = AppBehaviorModel(store: store, reloadConfig: {})
    model.discover([("com.apple.Safari", "Safari"), ("com.apple.Terminal", "Terminal"), ("com.apple.finder", "Finder")])
    model.setBehavior(.ribbon, bundleID: "com.apple.Terminal", name: "Terminal")
    model.setBehavior(.ask, bundleID: "com.apple.Safari", name: "Safari")
    model.setBehavior(.floating, bundleID: "com.apple.finder", name: "Finder")
    model.search = "safari"
    assert(model.apps.count == 1)
    model.search = "com.apple.terminal"
    assert(model.apps.first?.behavior == .ribbon)
    model.search = ""
    let persisted = try! store.read()
    assert(persisted.apps.count == 3 && persisted.history.count == 3)
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    func render<V: View>(_ view: V, size: NSSize, name: String) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("render failed") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
        window.close()
    }
    render(AppBehaviorView(model: model), size: NSSize(width: 860, height: 680), name: "app-behavior.png")
    let event = try! JSONDecoder().decode(
        AppBehaviorEvent.self,
        from: Data(
            #"{"event":"window_opened","window_id":42,"pid":123,"app_name":"Safari","bundle_id":"com.apple.Safari","floating":true,"startup":false}"#
                .utf8))
    render(
        AppBehaviorPrompt(event: event, choose: { _, _ in }), size: NSSize(width: 396, height: 190),
        name: "app-behavior-prompt.png")
    model.setPrompts(true)
    model.clearHistory()
    assert(model.data.history.isEmpty && model.data.promptForNewWindows)
    model.resetPreferences()
    assert(model.data.apps.allSatisfy { $0.behavior == .inherit } && !model.data.promptForNewWindows)
    assert(model.data.history.count == 1)
    print(
        "App Behavior UI/model: search, app overrides, save, global prompts, clear log, reset and offscreen renders passed."
    )
}
