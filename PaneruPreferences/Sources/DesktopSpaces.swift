import AppKit
import Foundation
import Darwin

struct DesktopSpace: Equatable, Codable, Sendable {
    let uuid: String
    let id: UInt64
    let name: String
    let visible: Bool
    let displayUUID: String
}

struct DesktopSpaces: Codable, Sendable {
    let spaces: [DesktopSpace]
    let currentUUID: String?

    var current: DesktopSpace? { spaces.first { $0.uuid == currentUUID } }

    func isSuspended(disabled: [String]) -> Bool {
        current.map { disabled.contains($0.uuid) } ?? false
    }

    func isDisabled(at point: CGPoint, disabled: [String]) -> Bool {
        guard !disabled.isEmpty else { return false }
        for (bounds, display) in DesktopDisplayMap.shared.entries where bounds.contains(point) {
            return spaces.contains { $0.visible && $0.displayUUID == display && disabled.contains($0.uuid) }
        }
        return isSuspended(disabled: disabled)
    }

    // Paneru's engine uses the same SkyLight API. UUIDs survive Space reordering
    // and login; numeric IDs are resolved again before each engine launch.
    static func read() -> DesktopSpaces {
        guard let api = DesktopSpaceAPI.shared else {
            return DesktopSpaces(spaces: [], currentUUID: nil)
        }
        let connection = api.mainConnection()
        let activeDisplay = api.copyActiveDisplay(connection)?.takeRetainedValue() as String?
        guard let raw = api.copySpaces(connection)?.takeRetainedValue(),
              let displays = raw as NSArray as? [[String: Any]] else {
            return DesktopSpaces(spaces: [], currentUUID: nil)
        }
        var result: [DesktopSpace] = []
        var currentUUID: String?
        for (displayIndex, display) in displays.enumerated() {
            guard let displayUUID = display["Display Identifier"] as? String else { continue }
            let current = display["Current Space"] as? [String: Any]
            let currentID = (current?["id64"] as? NSNumber)?.uint64Value
            let desktops = (display["Spaces"] as? [[String: Any]] ?? []).filter {
                ($0["type"] as? NSNumber)?.intValue == 0
            }
            for (desktopIndex, space) in desktops.enumerated() {
                guard let nativeUUID = space["uuid"] as? String,
                      let id = (space["id64"] as? NSNumber)?.uint64Value else { continue }
                // macOS can give the original desktop an empty UUID.
                let uuid = nativeUUID.isEmpty ? "native-root:\(id)" : nativeUUID
                let name = "Desktop \(desktopIndex + 1)" + (displays.count > 1 ? " · Display \(displayIndex + 1)" : "")
                result.append(DesktopSpace(uuid: uuid, id: id, name: name, visible: id == currentID, displayUUID: displayUUID))
                if id == currentID && (display["Display Identifier"] as? String == activeDisplay || displays.count == 1) {
                    currentUUID = uuid
                }
            }
        }
        return DesktopSpaces(spaces: result, currentUUID: currentUUID)
    }
}

// Function pointers remain valid while the framework handle is retained. Live
// Space state is still read at input time to protect desktop transitions.
private final class DesktopSpaceAPI {
    typealias MainConnection = @convention(c) () -> Int32
    typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopyActiveDisplay = @convention(c) (Int32) -> Unmanaged<CFString>?
    static let shared = DesktopSpaceAPI()
    private let library: UnsafeMutableRawPointer
    let mainConnection: MainConnection
    let copySpaces: CopySpaces
    let copyActiveDisplay: CopyActiveDisplay

    private init?() {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let main = dlsym(library, "SLSMainConnectionID"),
              let spaces = dlsym(library, "SLSCopyManagedDisplaySpaces"),
              let display = dlsym(library, "SLSCopyActiveMenuBarDisplayIdentifier") else {
            dlclose(library)
            return nil
        }
        self.library = library
        mainConnection = unsafeBitCast(main, to: MainConnection.self)
        copySpaces = unsafeBitCast(spaces, to: CopySpaces.self)
        copyActiveDisplay = unsafeBitCast(display, to: CopyActiveDisplay.self)
    }
    deinit { dlclose(library) }
}

// This cache is used only by the main-run-loop event tap. Screen changes
// invalidate geometry and UUIDs; active Space identity is never cached here.
private final class DesktopDisplayMap {
    static let shared = DesktopDisplayMap()
    private var cached: [(CGRect, String)]?
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                         object: nil, queue: .main) { [weak self] _ in
            self?.cached = nil
        }
    }
    var entries: [(CGRect, String)] {
        if let cached { return cached }
        let result: [(CGRect, String)] = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id.uint32Value)?.takeRetainedValue() else { return nil }
            return (CGDisplayBounds(id.uint32Value), CFUUIDCreateString(nil, uuid) as String)
        }
        cached = result
        return result
    }
}

@MainActor
final class DesktopSpaceController {
    private let model: SettingsModel
    private var observers: [NSObjectProtocol] = []
    private var busy = false
    private var pending = false
    private var session = DesktopSpaceSession()

    init(model: SettingsModel) { self.model = model }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     Notification.Name("NSWorkspaceActiveDisplayDidChangeNotification"),
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    func setRequested(_ enabled: Bool) {
        session.request(enabled)
        refresh()
    }

    func policyChanged() {
        session.policyChanged()
        refresh()
    }

    func refresh() {
        model.refreshDesktop()
        pending = true
        guard !busy && !model.applying else { return }
        busy = true
        Task {
            while pending {
                if model.applying { break }
                pending = false
                let running = await Task.detached { Engine.isRunning() }.value
                let preferences = PreferenceFiles.read()
                let excluded = DesktopSpaces.read().isSuspended(disabled: preferences.disabledSpaceUUIDs)
                let shouldRun = session.shouldRun(running: running, excluded: excluded)
                model.setDesktopSuspended(!shouldRun)
                do {
                    if shouldRun && !running {
                        try await Task.detached { try Engine.start() }.value
                    } else if !shouldRun && running {
                        try await Task.detached { try Engine.stop() }.value
                    }
                } catch {
                    model.failed = true
                    model.message = error.localizedDescription
                }
            }
            busy = false
        }
    }
}
