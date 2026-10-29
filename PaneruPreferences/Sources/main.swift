import AppKit
import SwiftUI
import Foundation

enum PreferenceFiles {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/paneru")
    static let json = directory.appendingPathComponent("preferences.json")
    static let lua = directory.appendingPathComponent("preferences.lua")
    static let script = directory.appendingPathComponent("init.lua")

    static func read() -> Preferences {
        guard let data = try? Data(contentsOf: json),
              let value = try? JSONDecoder().decode(Preferences.self, from: data) else { return .defaults }
        return value.validated
    }

    static func write(_ preferences: Preferences) throws {
        let value = preferences.validated
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: json, options: .atomic)
        let excludedIDs = DesktopSpaces.read().spaces.filter { value.disabledSpaceUUIDs.contains($0.uuid) }
            .map(\.id)
        let source = value.luaSource(disabledSpaceIDs: excludedIDs)
        try Data(source.utf8).write(to: lua, options: .atomic)
        for file in [json, lua] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    static func reload() throws {
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: script.path)
    }
}

struct CommandFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Engine {
    static let binary = Bundle.main.url(forAuxiliaryExecutable: "paneru")?.path ?? "/opt/homebrew/bin/paneru"
    static let service = "gui/\(getuid())/com.github.karinushka.paneru"

    @discardableResult
    static func run(_ arguments: [String], executable: String = binary, timeout: Double = 5) throws -> String {
        try CommandRunner.run(arguments, executable: executable, timeout: timeout)
    }

    static func isRunning() -> Bool {
        guard let text = try? run(["print", service], executable: "/bin/launchctl", timeout: 2) else { return false }
        return text.contains("state = running")
    }

    static func start() throws {
        let preferences = PreferenceFiles.read()
        guard !DesktopSpaces.read().isSuspended(disabled: preferences.disabledSpaceUUIDs) else { return }
        // Re-resolve stable Space UUIDs to this login's numeric engine IDs.
        try PreferenceFiles.write(preferences)
        if isRunning() {
            _ = try? run(["state", "set", "paneru.calibrating_layout", "false"])
            return
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let agent = directory.appendingPathComponent("com.github.karinushka.paneru.plist")
        try PrivateLogs.prepare()
        let logs = PrivateLogs.directory
        let definition: [String: Any] = [
            "Label": "com.github.karinushka.paneru", "Program": binary,
            "AssociatedBundleIdentifiers": ["local.paneru.preferences"],
            "RunAtLoad": false, "KeepAlive": false, "ProcessType": "Interactive",
            "MachServices": ["com.github.karinushka.paneru": true],
            "EnvironmentVariables": ["XDG_CONFIG_HOME": PreferenceFiles.directory.deletingLastPathComponent().path,
                                     "RUST_LOG": "warn", "NO_COLOR": "1"],
            "StandardErrorPath": logs.appendingPathComponent("stderr.log").path,
            "StandardOutPath": logs.appendingPathComponent("stdout.log").path
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
        try data.write(to: agent, options: .atomic)
        let loaded = try? run(["print", service], executable: "/bin/launchctl")
        let matches = loaded.map { $0.contains("program = \(binary)") && $0.contains(logs.path) } ?? false
        if loaded != nil && !matches {
            try run(["bootout", service], executable: "/bin/launchctl")
        }
        if !matches {
            try run(["bootstrap", "gui/\(getuid())", agent.path], executable: "/bin/launchctl")
        }
        try run(["kickstart", service], executable: "/bin/launchctl")
        Thread.sleep(forTimeInterval: 0.5)
        for _ in 0..<12 {
            if (try? run(["query", "active", "--json"], timeout: 2)) != nil {
                _ = try? run(["state", "set", "paneru.calibrating_layout", "false"])
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw CommandFailure(message: "RibbonDesk could not start. Check its Accessibility permission.")
    }

    static func stop() throws {
        guard isRunning() else { return }
        try run(["send-cmd", "quit"])
        for _ in 0..<30 {
            if !isRunning() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CommandFailure(message: "RibbonDesk is still closing. Please try again.")
    }

    static func normalizeActiveWorkspace() throws {
        let text = try run(["query", "state", "--json"])
        guard let data = text.data(using: .utf8),
              let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspaces = state["virtual_workspaces"] as? [[String: Any]],
              let active = workspaces.first(where: { $0["active"] as? Bool == true }),
              let windows = active["windows"] as? [[String: Any]] else { return }
        let count = windows.filter { $0["floating"] as? Bool != true }.count
        guard count > 0 else { return }
        try run(["state", "set", "paneru.calibrating_layout", "true"])
        defer { _ = try? run(["state", "set", "paneru.calibrating_layout", "false"]) }
        // This explicit gap refresh is the only focus-driven width calibration.
        // Ordinary hover and application activation never resize columns.
        for index in 1...min(count, 50) {
            try run(["send-cmd", "window", "focus", String(index)])
            Thread.sleep(forTimeInterval: 0.12)
        }
    }

    static func apply(_ preferences: Preferences, previous: Preferences) throws -> Bool {
        let wasRunning = isRunning()
        do {
            try PreferenceFiles.write(preferences)
            if wasRunning && preferences.disabledSpaceUUIDs != previous.disabledSpaceUUIDs {
                try stop()
                try start()
            } else if wasRunning && preferences.gap != previous.gap {
                try stop()
                try start()
                try normalizeActiveWorkspace()
            } else if preferences.scrollTuning != previous.scrollTuning
                        || preferences.infiniteRibbon != previous.infiniteRibbon
                        || preferences.floatingFollowsRibbon != previous.floatingFollowsRibbon
                        || preferences.trackpadHaptics != previous.trackpadHaptics
                        || preferences.focusMode != previous.focusMode
                        || preferences.borderEnabled != previous.borderEnabled || preferences.borderColor != previous.borderColor {
                try PreferenceFiles.reload()
            }
            return wasRunning
        } catch {
            try? PreferenceFiles.write(previous)
            try? PreferenceFiles.reload()
            if wasRunning && !isRunning() { try? start() }
            throw error
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var speed: Double { didSet { preferenceChanged() } }
    @Published var momentum: Double { didSet { preferenceChanged() } }
    @Published var momentumDecay: Double { didSet { preferenceChanged() } }
    @Published var snapSpeed: Double { didSet { preferenceChanged() } }
    @Published var snapVisible: Double { didSet { preferenceChanged() } }
    @Published var snapAnimation: Double { didSet { preferenceChanged() } }
    @Published var snapFullWidth: Bool { didSet { preferenceChanged() } }
    @Published var snapHalfWidth: Bool { didSet { preferenceChanged() } }
    @Published var snapBack: Bool { didSet { preferenceChanged() } }
    @Published var snapExitDistance: Double { didSet { preferenceChanged() } }
    @Published var magneticSnapping: Bool { didSet { preferenceChanged() } }
    @Published var magnetStrength: Double { didSet { preferenceChanged() } }
    @Published var magnetRange: Double { didSet { preferenceChanged() } }
    @Published var threeFingerPaging: Bool { didSet { preferenceChanged() } }
    @Published var infiniteRibbon: Bool { didSet { preferenceChanged() } }
    @Published var floatingFollowsRibbon: Bool { didSet { preferenceChanged() } }
    @Published var trackpadHaptics: Bool { didSet { preferenceChanged() } }
    @Published var overviewAnimation: Bool { didSet { preferenceChanged() } }
    @Published var gap: Double { didSet { preferenceChanged() } }
    @Published var focusMode: FocusMode { didSet { preferenceChanged() } }
    @Published var launchAtLogin: Bool { didSet { preferenceChanged() } }
    @Published var disabledSpaceUUIDs: [String] { didSet { preferenceChanged() } }
    @Published var borderEnabled: Bool { didSet { preferenceChanged() } }
    @Published var borderColorHex: String { didSet { preferenceChanged() } }
    @Published var desktop: DesktopSpace?
    @Published var desktopSuspended = false
    @Published var loginApprovalRequired = LoginItem.requiresApproval
    @Published var accessibilityGranted = ActivationClickGuard.isAuthorized
    @Published var engineRunning = false { didSet { engineRunningChanged?() } }
    var engineRunningChanged: (() -> Void)?
    @Published var engineBusy = false { didSet { engineActivityChanged?(engineBusy) } }
    var engineActivityChanged: ((Bool) -> Void)?
    var toggleEngineAction: (() -> Void)?
    var overviewAction: (() -> Void)?
    var appBehaviorAction: (() -> Void)?
    var restartEngineAction: (() -> Void)?
    var quitAction: (() -> Void)?
    @Published var applying = false
    @Published var message = "Changes apply automatically."
    @Published var presets: [ScrollPreset] = []
    @Published var selectedPresetID = ""
    @Published var presetName = ""
    private let presetStore = ScrollPresetStore(url: PreferenceFiles.directory.appendingPathComponent("scroll-presets.json"))
    @Published var failed = false
    private var saved: Preferences
    private let clickGuard = ActivationClickGuard()
    var willApply: ((Bool) -> Void)?
    var didApply: (() -> Void)?
    private var protectionSuspended = false
    private var restoring = false
    private lazy var autosaver: PreferencesAutosaver = {
        let saver = PreferencesAutosaver(initial: saved) { [weak self] next, previous in
            try await self?.apply(next, previous: previous)
        }
        saver.onBusy = { [weak self] in
            self?.applying = true
            self?.failed = false
        }
        saver.onStart = { [weak self] next, previous in
            guard let self else { return }
            failed = false
            let layout = next.gap != previous.gap || next.disabledSpaceUUIDs != previous.disabledSpaceUUIDs
            message = layout ? "Refreshing the window layout…" : "Applying…"
            willApply?(layout)
        }
        saver.onApplied = { [weak self] next, previous in
            guard let self else { return }
            saved = next
            loginApprovalRequired = LoginItem.requiresApproval
            message = "Settings saved automatically."
            if DesktopSpaces.read().isSuspended(disabled: next.disabledSpaceUUIDs) {
                message = "RibbonDesk is disabled on this Desktop."
            } else if previous.disabledSpaceUUIDs != next.disabledSpaceUUIDs {
                message = "This Desktop is enabled."
            }
            if loginApprovalRequired { message = "Approve RibbonDesk in Login Items to launch at login." }
        }
        saver.onFailure = { [weak self] error, applied, hasNewerEdit in
            guard let self else { return }
            if !hasNewerEdit { setDraft(applied) }
            accessibilityGranted = ActivationClickGuard.isAuthorized
            failed = true
            message = "Couldn’t apply settings. " + error.localizedDescription
            NSLog("RibbonDesk: %@", error.localizedDescription)
        }
        saver.onIdle = { [weak self] in
            self?.applying = false
            self?.didApply?()
        }
        return saver
    }()

    init() {
        var preferences = PreferenceFiles.read()
        preferences.launchAtLogin = LoginItem.enabled
        saved = preferences
        speed = preferences.speed
        momentum = preferences.momentum
        momentumDecay = preferences.momentumDecay
        snapSpeed = preferences.snapSpeed
        snapVisible = preferences.snapVisible
        snapAnimation = preferences.snapAnimation
        snapFullWidth = preferences.snapFullWidth
        snapHalfWidth = preferences.snapHalfWidth
        snapBack = preferences.snapBack
        snapExitDistance = preferences.snapExitDistance
        threeFingerPaging = preferences.threeFingerPaging
        magneticSnapping = preferences.magneticSnapping
        magnetStrength = preferences.magnetStrength
        magnetRange = preferences.magnetRange
        infiniteRibbon = preferences.infiniteRibbon
        floatingFollowsRibbon = preferences.floatingFollowsRibbon
        trackpadHaptics = preferences.trackpadHaptics
        overviewAnimation = preferences.overviewAnimation
        gap = Double(preferences.gap)
        focusMode = preferences.focusMode
        launchAtLogin = preferences.launchAtLogin
        disabledSpaceUUIDs = preferences.disabledSpaceUUIDs
        borderEnabled = preferences.borderEnabled
        borderColorHex = preferences.borderColor
        do { presets = try presetStore.read() }
        catch { failed = true; message = "Couldn’t read feel presets. " + error.localizedDescription }
        desktop = DesktopSpaces.read().current
        clickGuard.shouldHandlePoint = { [weak self] point in
            let disabled = self?.saved.disabledSpaceUUIDs ?? []
            return disabled.isEmpty || !DesktopSpaces.read().isDisabled(at: point, disabled: disabled)
        }
        protectionSuspended = DesktopSpaces.read().isSuspended(disabled: preferences.disabledSpaceUUIDs)
        desktopSuspended = protectionSuspended
        do { try clickGuard.configure(for: protectionSuspended ? .hover : focusMode) }
        catch { failed = true; message = error.localizedDescription }
    }

    var draft: Preferences {
        Preferences(speed: (speed * 100).rounded() / 100, gap: Int(gap.rounded()),
                    focusMode: focusMode, launchAtLogin: launchAtLogin,
                    disabledSpaceUUIDs: disabledSpaceUUIDs, borderEnabled: borderEnabled,
                    borderColor: BorderColor.parsedHex(borderColorHex) ?? saved.borderColor,
                    momentum: (momentum * 100).rounded() / 100,
                    snapSpeed: (snapSpeed * 100).rounded() / 100,
                    snapVisible: (snapVisible * 100).rounded() / 100,
                    momentumDecay: (momentumDecay * 100).rounded() / 100,
                    snapAnimation: (snapAnimation * 100).rounded() / 100,
                    snapFullWidth: snapFullWidth, snapHalfWidth: snapHalfWidth, snapBack: snapBack,
                    snapExitDistance: (snapExitDistance * 100).rounded() / 100,
                    threeFingerPaging: threeFingerPaging, overviewAnimation: overviewAnimation,
                    infiniteRibbon: infiniteRibbon, magneticSnapping: magneticSnapping,
                    magnetStrength: (magnetStrength * 100).rounded() / 100,
                    magnetRange: (magnetRange * 100).rounded() / 100,
                    floatingFollowsRibbon: floatingFollowsRibbon, trackpadHaptics: trackpadHaptics).validated
    }

    var borderColor: Color {
        get {
            let rgb = BorderColor.components(BorderColor.parsedHex(borderColorHex) ?? saved.borderColor)
            return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
        set {
            guard let rgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            borderColorHex = BorderColor.hex(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        }
    }

    var currentDesktopEnabled: Bool {
        get { desktop.map { !disabledSpaceUUIDs.contains($0.uuid) } ?? true }
        set {
            guard let desktop else { return }
            disabledSpaceUUIDs.removeAll { $0 == desktop.uuid }
            if !newValue { disabledSpaceUUIDs.append(desktop.uuid) }
        }
    }

    func refreshDesktop() { desktop = DesktopSpaces.read().current }

    func setDesktopSuspended(_ suspended: Bool) {
        protectionSuspended = suspended
        desktopSuspended = suspended
        do { try clickGuard.configure(for: suspended ? .hover : saved.focusMode) }
        catch { failed = true; message = error.localizedDescription }
    }

    func refresh() {
        accessibilityGranted = ActivationClickGuard.isAuthorized
        refreshDesktop()
        guard !applying else { return }
        var current = PreferenceFiles.read()
        current.launchAtLogin = LoginItem.enabled
        loginApprovalRequired = LoginItem.requiresApproval
        if current != saved {
            saved = current
            autosaver.replaceApplied(current)
            setDraft(current)
        }
        do { try clickGuard.configure(for: protectionSuspended ? .hover : current.focusMode) }
        catch { failed = true; message = error.localizedDescription }
    }

    private func setDraft(_ value: Preferences) {
        restoring = true
        defer { restoring = false }
        speed = value.speed
        momentum = value.momentum
        momentumDecay = value.momentumDecay
        snapSpeed = value.snapSpeed
        snapVisible = value.snapVisible
        snapAnimation = value.snapAnimation
        snapFullWidth = value.snapFullWidth
        snapHalfWidth = value.snapHalfWidth
        snapBack = value.snapBack
        snapExitDistance = value.snapExitDistance
        threeFingerPaging = value.threeFingerPaging
        magneticSnapping = value.magneticSnapping
        magnetStrength = value.magnetStrength
        magnetRange = value.magnetRange
        infiniteRibbon = value.infiniteRibbon
        floatingFollowsRibbon = value.floatingFollowsRibbon
        trackpadHaptics = value.trackpadHaptics
        overviewAnimation = value.overviewAnimation
        gap = Double(value.gap)
        focusMode = value.focusMode
        launchAtLogin = value.launchAtLogin
        disabledSpaceUUIDs = value.disabledSpaceUUIDs
        borderEnabled = value.borderEnabled
        borderColorHex = value.borderColor
    }

    private func preferenceChanged() {
        guard !restoring else { return }
        autosaver.submit(draft)
    }

    func reset() {
        setDraft(.defaults)
        preferenceChanged()
    }

    func savePreset() {
        do {
            let preset = try presetStore.save(name: presetName, tuning: draft.scrollTuning)
            presets = try presetStore.read()
            selectedPresetID = preset.id
            presetName = preset.name
            failed = false
            message = "Saved feel preset ‘\(preset.name)’."
        } catch { failed = true; message = "Couldn’t save preset. " + error.localizedDescription }
    }

    func loadPreset() {
        guard let preset = presets.first(where: { $0.id == selectedPresetID }) else { return }
        var next = draft
        next.scrollTuning = preset.tuning.validated
        setDraft(next)
        presetName = preset.name
        preferenceChanged()
    }

    func deletePreset() {
        guard !selectedPresetID.isEmpty else { return }
        do {
            try presetStore.delete(id: selectedPresetID)
            presets = try presetStore.read()
            selectedPresetID = ""
            presetName = ""
            failed = false
            message = "Feel preset deleted. Current settings are unchanged."
        } catch { failed = true; message = "Couldn’t delete preset. " + error.localizedDescription }
    }

    func commitBorderColor() {
        borderColorHex = BorderColor.parsedHex(borderColorHex) ?? saved.borderColor
    }

    private func apply(_ next: Preferences, previous: Preferences) async throws {
        do {
            let suspended = DesktopSpaces.read().isSuspended(disabled: next.disabledSpaceUUIDs)
            if next.focusMode == .click && !suspended { try clickGuard.configure(for: .click) }
            if next.launchAtLogin != previous.launchAtLogin { try LoginItem.setEnabled(next.launchAtLogin) }
            _ = try await Task.detached { try Engine.apply(next, previous: previous) }.value
            if next.focusMode == .hover || suspended { try clickGuard.configure(for: .hover) }
        } catch {
            if next.launchAtLogin != previous.launchAtLogin { try? LoginItem.setEnabled(previous.launchAtLogin) }
            try? clickGuard.configure(for: protectionSuspended ? .hover : previous.focusMode)
            throw error
        }
    }

    func allowClickMode() {
        ActivationClickGuard.requestAuthorization()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

enum Icon {
    static func drawPanes(in rect: NSRect, color: NSColor, lineWidth: CGFloat) {
        color.setStroke()
        let sx = rect.width / 22, sy = rect.height / 20
        for x in [2.0, 9.0, 16.0] {
            let frame = NSRect(x: rect.minX + x * sx, y: rect.minY + 3 * sy, width: 4 * sx, height: 14 * sy)
            let path = NSBezierPath(roundedRect: frame, xRadius: sx, yRadius: sy)
            path.lineWidth = lineWidth
            path.stroke()
        }
    }

    static var menu: NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 20), flipped: false) { rect in
            drawPanes(in: rect, color: .black, lineWidth: 1.35)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "RibbonDesk"
        return image
    }

    static func export(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let iconset = directory.appendingPathComponent("RibbonDesk.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let image = NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { rect in
                    NSColor(calibratedRed: 0.20, green: 0.53, blue: 0.62, alpha: 1).setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04),
                                 xRadius: rect.width * 0.22, yRadius: rect.height * 0.22).fill()
                    drawPanes(in: rect.insetBy(dx: rect.width * 0.19, dy: rect.height * 0.19), color: .white, lineWidth: rect.width * 0.025)
                    return true
                }
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
                if size == 256 && scale == 1 {
                    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("RibbonDesk-logo.png"))
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let contextMenu = NSMenu()
    private let model = SettingsModel()
    private lazy var desktops = DesktopSpaceController(model: model)
    private let overview = RibbonOverviewController()
    private let appBehavior = AppBehaviorController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        overview.canShow = { [weak self] in
            guard let self else { return false }
            return self.model.engineRunning && !self.model.engineBusy && !self.model.applying
                && !DesktopSpaces.read().isSuspended(disabled: PreferenceFiles.read().disabledSpaceUUIDs)
        }
        overview.willShow = { [weak self] in self?.popover.performClose(nil) }
        overview.animateTransitions = { [weak self] in self?.model.overviewAnimation ?? false }
        overview.infiniteRibbon = { [weak self] in self?.model.infiniteRibbon ?? false }
        appBehavior.canPrompt = { [weak self] in
            guard let self else { return false }
            return self.model.engineRunning && !self.model.engineBusy && !self.model.applying
                && !self.overview.isVisible && !self.popover.isShown
                && !DesktopSpaces.read().isSuspended(disabled: self.model.disabledSpaceUUIDs)
        }
        let controller = NSHostingController(rootView: SettingsView(model: model)
            .onExitCommand { [weak self] in self?.popover.performClose(nil) })
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        popover.behavior = .transient
        popover.delegate = self
        model.willApply = { [weak self] layout in
            // A gap refresh briefly focuses managed windows. Keep the controls
            // visible until that operation finishes, then restore normal dismissal.
            guard let self, layout, self.popover.isShown else { return }
            self.popover.behavior = .applicationDefined
        }
        model.didApply = { [weak self] in
            guard let self else { return }
            self.desktops.policyChanged()
            self.restorePopoverAfterOperation()
        }
        model.engineActivityChanged = { [weak self] busy in
            guard let self else { return }
            self.appBehavior.sync(running: self.model.engineRunning && !busy)
            if busy, self.popover.isShown { self.popover.behavior = .applicationDefined }
            else if !busy { self.restorePopoverAfterOperation() }
        }
        model.engineRunningChanged = { [weak self] in
            guard let self else { return }
            self.appBehavior.sync(running: self.model.engineRunning && !self.model.engineBusy)
        }
        model.toggleEngineAction = { [weak self] in self?.overview.close(); self?.desktops.setRequested(!(self?.model.engineRunning ?? false)) }
        model.restartEngineAction = { [weak self] in self?.overview.close(); self?.desktops.restart() }
        model.overviewAction = { [weak self] in self?.overview.show() }
        model.appBehaviorAction = { [weak self] in self?.openAppBehavior() }
        model.quitAction = { [weak self] in self?.quitAll() }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Icon.menu
        item.button?.toolTip = "RibbonDesk — click for settings, right-click to quit"
        item.button?.setAccessibilityLabel("RibbonDesk")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        contextMenu.delegate = self
        contextMenu.autoenablesItems = false
        contextMenu.addItem(menuItem("App Behavior…", action: #selector(openAppBehavior)))
        contextMenu.addItem(menuItem("Quit RibbonDesk", action: #selector(quitAll)))
        if !CommandLine.arguments.contains("--background") && !LoginItem.launchedAtLogin { openSettings() }
        desktops.start()
    }

    private func restorePopoverAfterOperation() {
        guard !model.applying && !model.engineBusy else { return }
        let restoreFocus = popover.behavior == .applicationDefined
        popover.behavior = .transient
        guard restoreFocus, popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items { item.isEnabled = !model.applying && !model.engineBusy }

    }

    @objc private func statusItemClicked() {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            contextMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            openSettings()
        }
    }

    @objc func openSettings() {
        overview.close()
        guard let button = item.button else { return }
        if !popover.isShown {
            model.refresh()
            desktops.refresh()
        }
        if model.engineBusy { popover.behavior = .applicationDefined }
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = view.fittingSize
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
    }

    func popoverDidClose(_ notification: Notification) {
        item.button?.highlight(false)
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        popover.behavior != .applicationDefined
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    @objc private func openAppBehavior() {
        popover.performClose(nil)
        overview.close()
        appBehavior.showSettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        overview.close(restoreFocus: false)
        appBehavior.stop()
    }

    @objc private func quitAll() {
        guard !model.applying && !model.engineBusy else { return }
        overview.close(restoreFocus: false)
        model.engineBusy = true
        Task {
            defer { model.engineBusy = false }
            do { try await Task.detached { try Engine.stop() }.value; NSApp.terminate(nil) }
            catch { model.failed = true; model.message = error.localizedDescription; openSettings() }
        }
    }
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--render-assets" {
    try Icon.export(to: URL(fileURLWithPath: CommandLine.arguments[2]))
} else if CommandLine.arguments.contains("--desktop-state") {
    let data = try JSONEncoder().encode(DesktopSpaces.read())
    print(String(decoding: data, as: UTF8.self))
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
