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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            throw CommandFailure(message: "Paneru did not respond in time.")
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CommandFailure(message: String(text.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
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
        let definition: [String: Any] = [
            "Label": "com.github.karinushka.paneru", "Program": binary,
            "RunAtLoad": false, "KeepAlive": false, "ProcessType": "Interactive",
            "MachServices": ["com.github.karinushka.paneru": true],
            "EnvironmentVariables": ["XDG_CONFIG_HOME": PreferenceFiles.directory.deletingLastPathComponent().path,
                                     "RUST_LOG": "warn", "NO_COLOR": "1"],
            "StandardErrorPath": "/tmp/com.github.karinushka.paneru_\(getuid()).err.log",
            "StandardOutPath": "/tmp/com.github.karinushka.paneru_\(getuid()).out.log"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
        try data.write(to: agent, options: .atomic)
        let loaded = try? run(["print", service], executable: "/bin/launchctl")
        if let loaded, !loaded.contains("program = \(binary)") {
            try run(["bootout", service], executable: "/bin/launchctl")
        }
        if loaded == nil || loaded?.contains("program = \(binary)") != true {
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
        throw CommandFailure(message: "Paneru could not start. Check its Accessibility permission.")
    }

    static func stop() throws {
        guard isRunning() else { return }
        try run(["send-cmd", "quit"])
        for _ in 0..<30 {
            if !isRunning() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CommandFailure(message: "Paneru is still closing. Please try again.")
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
            } else if preferences.speed != previous.speed || preferences.focusMode != previous.focusMode
                        || preferences.borderEnabled != previous.borderEnabled || preferences.borderColor != previous.borderColor {
                try PreferenceFiles.reload()
                Thread.sleep(forTimeInterval: 0.25)
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
    @Published var speed: Double
    @Published var gap: Double
    @Published var focusMode: FocusMode
    @Published var launchAtLogin: Bool
    @Published var disabledSpaceUUIDs: [String]
    @Published var borderEnabled: Bool
    @Published var borderColorHex: String
    @Published var desktop: DesktopSpace?
    @Published var desktopSuspended = false
    @Published var loginApprovalRequired = LoginItem.requiresApproval
    @Published var accessibilityGranted = ActivationClickGuard.isAuthorized
    @Published var applying = false
    @Published var message = "Changes apply when you choose Save."
    @Published var failed = false
    private var saved: Preferences
    private let clickGuard = ActivationClickGuard()
    var willApply: (() -> Void)?
    var didApply: (() -> Void)?
    private var protectionSuspended = false

    init() {
        var preferences = PreferenceFiles.read()
        preferences.launchAtLogin = LoginItem.enabled
        saved = preferences
        speed = preferences.speed
        gap = Double(preferences.gap)
        focusMode = preferences.focusMode
        launchAtLogin = preferences.launchAtLogin
        disabledSpaceUUIDs = preferences.disabledSpaceUUIDs
        borderEnabled = preferences.borderEnabled
        borderColorHex = preferences.borderColor
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

    var draft: Preferences { Preferences(speed: (speed * 100).rounded() / 100, gap: Int(gap.rounded()), focusMode: focusMode, launchAtLogin: launchAtLogin, disabledSpaceUUIDs: disabledSpaceUUIDs, borderEnabled: borderEnabled, borderColor: borderColorHex).validated }
    var changed: Bool { draft != saved }

    var borderColor: Color {
        get {
            let rgb = BorderColor.components(borderColorHex)
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
        // Retain an unsaved choice while the user grants Accessibility in Settings.
        if current != saved {
            saved = current
            speed = saved.speed
            gap = Double(saved.gap)
            focusMode = saved.focusMode
            launchAtLogin = saved.launchAtLogin
            disabledSpaceUUIDs = saved.disabledSpaceUUIDs
            borderEnabled = saved.borderEnabled
            borderColorHex = saved.borderColor
        }
        do { try clickGuard.configure(for: protectionSuspended ? .hover : current.focusMode) }
        catch { failed = true; message = error.localizedDescription }
    }

    func reset() {
        speed = Preferences.defaults.speed
        gap = Double(Preferences.defaults.gap)
        focusMode = Preferences.defaults.focusMode
        launchAtLogin = Preferences.defaults.launchAtLogin
        disabledSpaceUUIDs = Preferences.defaults.disabledSpaceUUIDs
        borderEnabled = Preferences.defaults.borderEnabled
        borderColorHex = Preferences.defaults.borderColor
        message = "Defaults selected. Choose Save to apply."
        failed = false
    }

    func save() {
        guard changed && !applying else { return }
        let next = draft, previous = saved
        do {
            // Do not save Click mode unless activation-only clicks can be enforced.
            if next.focusMode == .click && !protectionSuspended { try clickGuard.configure(for: .click) }
        } catch {
            accessibilityGranted = ActivationClickGuard.isAuthorized
            failed = true
            message = error.localizedDescription
            return
        }
        applying = true
        willApply?()
        failed = false
        message = next.gap == previous.gap ? "Saving…" : "Refreshing the window layout…"
        Task {
            do {
                try LoginItem.setEnabled(next.launchAtLogin)
                let running = try await Task.detached { try Engine.apply(next, previous: previous) }.value
                if next.focusMode == .hover { try clickGuard.configure(for: .hover) }
                saved = next
                speed = next.speed
                gap = Double(next.gap)
                focusMode = next.focusMode
                launchAtLogin = next.launchAtLogin
                disabledSpaceUUIDs = next.disabledSpaceUUIDs
                borderEnabled = next.borderEnabled
                borderColorHex = next.borderColor
                loginApprovalRequired = LoginItem.requiresApproval
                message = running ? "Saved. Your settings are active." : "Saved for the next time Paneru starts."
                if DesktopSpaces.read().isSuspended(disabled: next.disabledSpaceUUIDs) {
                    message = "Saved. Paneru is disabled on this Desktop."
                } else if previous.disabledSpaceUUIDs != next.disabledSpaceUUIDs {
                    message = "Saved. This Desktop is enabled."
                }
                if loginApprovalRequired { message = "Saved. Approve Paneru Settings in Login Items to launch at login." }
            } catch {
                try? LoginItem.setEnabled(previous.launchAtLogin)
                try? clickGuard.configure(for: protectionSuspended ? .hover : previous.focusMode)
                failed = true
                message = "Couldn’t apply settings. Previous settings restored."
                NSLog("Paneru Settings: %@", error.localizedDescription)
            }
            applying = false
            didApply?()
        }
    }

    func allowClickMode() {
        ActivationClickGuard.requestAuthorization()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

struct Panes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scale = min(rect.width / 22, rect.height / 20)
        let origin = CGPoint(x: rect.midX - 11 * scale, y: rect.midY - 10 * scale)
        for x in [2.0, 9.0, 16.0] {
            let frame = CGRect(x: origin.x + x * scale, y: origin.y + 3 * scale, width: 4 * scale, height: 14 * scale)
            path.addRoundedRect(in: frame, cornerSize: CGSize(width: scale, height: scale))
        }
        return path
    }
}

struct SettingsView: View {
    static let width: CGFloat = 380
    @ObservedObject var model: SettingsModel
    private let accent = Color(red: 0.20, green: 0.53, blue: 0.62)
    private let shortcuts = [
        ("Previous / next window", "H / L or ← / →"),
        ("Move window left / right", "J / K"),
        ("Half width", "2"),
        ("Full width", "0 / F"),
        ("Toggle half / full", "R"),
        ("Toggle floating", "T"),
        ("First / last window", "Home / End"),
        ("Open settings", "S"),
        ("Pause window management", "Q")
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Panes().stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .padding(5).frame(width: 28, height: 28)
                        .background(accent.gradient, in: RoundedRectangle(cornerRadius: 8))
                    Text("Paneru").font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("Settings").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("Activate on").font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                        Picker("Activate windows", selection: $model.focusMode) {
                            Text("Mouse over").tag(FocusMode.hover)
                            Text("Click").tag(FocusMode.click)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    }
                    Text(model.focusMode == .hover
                         ? "Hover over a window to activate it."
                         : "First click activates. Click again to interact.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if model.focusMode == .click && !model.accessibilityGranted {
                        Button("Allow Click Mode…", action: model.allowClickMode)
                        Text("Allow Accessibility for Paneru Settings, then choose Save.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(10).background(.background, in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Enable on this Desktop", isOn: $model.currentDesktopEnabled)
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 12, weight: .medium))
                        .disabled(model.desktop == nil)
                    Text(model.desktop.map { "\($0.name) · Off disables tiling, gestures, activation, and hotkeys." }
                         ?? "Switch to a desktop Space to change this option.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }

                Toggle(isOn: $model.launchAtLogin) {
                    HStack(spacing: 6) {
                        Text("Launch at login").font(.system(size: 12, weight: .medium))
                        Text("Paneru + menu bar").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel("Launch at login")
                    .accessibilityHint("Starts Paneru and the menu-bar app automatically when you log in.")
                if model.loginApprovalRequired {
                    Button("Approve in Login Items…", action: LoginItem.openSettings)
                }

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Scroll speed").frame(width: 78, alignment: .leading)
                        Slider(value: $model.speed, in: 0.2...1.5, step: 0.05)
                            .accessibilityLabel("Scroll speed")
                            .help("Move left for slower scrolling, right for faster scrolling.")
                        Text(String(format: "%.2f×", model.speed)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                    }
                    HStack(spacing: 8) {
                        Text("Window gap").frame(width: 78, alignment: .leading)
                        Slider(value: $model.gap, in: 0...24, step: 2)
                            .accessibilityLabel("Window gap")
                            .help("Gap changes briefly refresh the window layout.")
                        Text("\(Int(model.gap)) pt").monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                    }
                }.font(.system(size: 12)).controlSize(.small)
                    .padding(10).background(.background, in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Toggle("Active window outline", isOn: $model.borderEnabled)
                            .toggleStyle(.switch).controlSize(.mini)
                            .font(.system(size: 12, weight: .medium))
                        ColorPicker("Outline color", selection: $model.borderColor, supportsOpacity: false)
                            .labelsHidden().fixedSize()
                            .disabled(!model.borderEnabled)
                            .accessibilityLabel("Outline color")
                            .help("Choose the active window’s outline color, then Save.")
                        TextField("#RRGGBB", text: $model.borderColorHex)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 74)
                            .disabled(!model.borderEnabled)
                            .accessibilityLabel("Outline color hex")
                            .help("Enter a six-digit hex color, such as #33879E, then Save.")
                            .onSubmit { model.borderColorHex = BorderColor.normalized(model.borderColorHex) }
                    }
                    Text("A thin outline highlights the active window.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Keyboard shortcuts", systemImage: "keyboard").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("Control + Option").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 3) {
                        ForEach(shortcuts, id: \.0) { item in
                            HStack {
                                Text(item.0).font(.system(size: 11))
                                Spacer()
                                Text(item.1).font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            }.frame(minHeight: 16)
                        }
                    }
                }
                Text("Click to work in place. ⌘-click a window to snap it into view.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if model.applying { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.failed ? "exclamationmark.circle" : "checkmark.circle") }
                    Text(model.message).lineLimit(2)
                }.font(.system(size: 10)).foregroundStyle(model.failed ? Color.red : Color.secondary)
                    .frame(height: 26, alignment: .leading)
                HStack {
                    Button("Reset Defaults", action: model.reset)
                    Spacer()
                    Button("Save", action: model.save).buttonStyle(.borderedProminent)
                        .disabled(!model.changed || model.applying)
                }
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 10)
        }.frame(width: Self.width).fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(accent)
            .disabled(model.applying)
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
        image.accessibilityDescription = "Paneru"
        return image
    }

    static func export(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let iconset = directory.appendingPathComponent("Paneru.iconset")
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
                    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("Paneru-logo.png"))
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
    private var toggleItem: NSMenuItem!
    private let model = SettingsModel()
    private lazy var desktops = DesktopSpaceController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let controller = NSHostingController(rootView: SettingsView(model: model)
            .onExitCommand { [weak self] in self?.popover.performClose(nil) })
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        popover.behavior = .transient
        popover.delegate = self
        model.willApply = { [weak self] in
            // A gap refresh briefly focuses managed windows. Keep the controls
            // visible until that operation finishes, then restore normal dismissal.
            guard let self, self.popover.isShown else { return }
            self.popover.behavior = .applicationDefined
        }
        model.didApply = { [weak self] in
            guard let self else { return }
            self.desktops.policyChanged()
            self.popover.behavior = .transient
            guard self.popover.isShown else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Icon.menu
        item.button?.toolTip = "Paneru — click for settings, right-click for window management"
        item.button?.setAccessibilityLabel("Paneru")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        contextMenu.delegate = self
        contextMenu.autoenablesItems = false
        contextMenu.addItem(menuItem("Settings…", action: #selector(openSettings)))
        contextMenu.addItem(.separator())
        toggleItem = menuItem("Pause Window Management", action: #selector(toggleEngine))
        contextMenu.addItem(toggleItem)
        contextMenu.addItem(menuItem("Restart Paneru", action: #selector(restartEngine)))
        contextMenu.addItem(.separator())
        contextMenu.addItem(menuItem("Quit Paneru", action: #selector(quitAll)))
        if !CommandLine.arguments.contains("--background") && !LoginItem.launchedAtLogin { openSettings() }
        desktops.start()
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // A read of launchd does not wake a paused engine.
        let disabled = DesktopSpaces.read().isSuspended(disabled: PreferenceFiles.read().disabledSpaceUUIDs)
        toggleItem.title = disabled ? "Disabled on this Desktop" : (Engine.isRunning() ? "Pause Window Management" : "Start Window Management")
        for item in menu.items where !item.isSeparatorItem { item.isEnabled = !model.applying }
        toggleItem.isEnabled = !model.applying && !disabled
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
        guard let button = item.button else { return }
        if !popover.isShown { model.refresh() }
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
        !model.applying
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    @objc private func toggleEngine() {
        desktops.setRequested(!Engine.isRunning())
    }

    @objc private func restartEngine() {
        Task {
            do {
                try await Task.detached { try Engine.stop() }.value
                desktops.setRequested(true)
            }
            catch { model.failed = true; model.message = error.localizedDescription; openSettings() }
        }
    }

    @objc private func quitAll() {
        Task {
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
