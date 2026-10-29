import Foundation

enum AppWindowBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case inherit, ribbon, floating, ask
    var id: String { rawValue }
    var label: String {
        switch self {
        case .inherit: return "Use global default"
        case .ribbon: return "Automatically join Ribbon"
        case .floating: return "Always start floating"
        case .ask: return "Ask each time"
        }
    }
    func shouldPrompt(global: Bool) -> Bool { self == .ask || (self == .inherit && global) }
}

/// The column width an app's windows take when they join the Ribbon.
enum AppWindowWidth: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, third, half, twoThirds, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic width"
        case .third: return "One third"
        case .half: return "Half"
        case .twoThirds: return "Two thirds"
        case .full: return "Full width"
        }
    }
    var ratio: Double? {
        switch self {
        case .automatic: return nil
        case .third: return 1.0 / 3.0
        case .half: return 0.5
        case .twoThirds: return 2.0 / 3.0
        case .full: return 1.0
        }
    }
}

struct AppBehaviorRule: Codable, Equatable, Identifiable, Sendable {
    var bundleID: String
    var name: String
    var behavior: AppWindowBehavior = .inherit
    var width: AppWindowWidth = .automatic
    var id: String { bundleID }

    init(bundleID: String, name: String, behavior: AppWindowBehavior = .inherit, width: AppWindowWidth = .automatic) {
        self.bundleID = bundleID
        self.name = name
        self.behavior = behavior
        self.width = width
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try values.decode(String.self, forKey: .bundleID)
        name = try values.decode(String.self, forKey: .name)
        behavior = try values.decodeIfPresent(AppWindowBehavior.self, forKey: .behavior) ?? .inherit
        // Catalogs saved before per-app widths keep the automatic width.
        width = try values.decodeIfPresent(AppWindowWidth.self, forKey: .width) ?? .automatic
    }
}

struct AppBehaviorLog: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var bundleID: String
    var appName: String
    var action: String
}

struct AppBehaviorData: Codable, Equatable, Sendable {
    static let historyLimit = 200
    var promptForNewWindows = false
    var apps: [AppBehaviorRule] = []
    var history: [AppBehaviorLog] = []

    func behavior(for bundleID: String) -> AppWindowBehavior {
        apps.first { $0.bundleID == bundleID }?.behavior ?? .inherit
    }

    func width(for bundleID: String) -> AppWindowWidth {
        apps.first { $0.bundleID == bundleID }?.width ?? .automatic
    }

    mutating func discover(bundleID: String, name: String) {
        guard !bundleID.isEmpty, bundleID != "local.paneru.preferences" else { return }
        if let index = apps.firstIndex(where: { $0.bundleID == bundleID }) {
            if !name.isEmpty { apps[index].name = String(name.prefix(200)) }
        } else {
            apps.append(AppBehaviorRule(bundleID: bundleID, name: String(name.prefix(200))))
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    mutating func record(bundleID: String, name: String, action: String) {
        history.insert(AppBehaviorLog(bundleID: bundleID, appName: String(name.prefix(200)), action: action), at: 0)
        history = Array(history.prefix(Self.historyLimit))
    }

    /// Quote UTF-8 bytes as Lua decimal escapes, including untrusted bundle IDs.
    private func luaString(_ string: String) -> String {
        "\"" + string.utf8.map { String(format: "\\%03d", Int($0)) }.joined() + "\""
    }

    var luaSource: String {
        let entries = apps.filter {
            ($0.behavior != .inherit || $0.width != .automatic) && $0.bundleID != "local.paneru.preferences"
        }
            .sorted { $0.bundleID < $1.bundleID }
            .map { app -> String in
                let behavior = luaString(app.behavior.rawValue)
                guard let ratio = app.width.ratio else { return "  [\(luaString(app.bundleID))] = \(behavior)," }
                let width = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), ratio)
                return "  [\(luaString(app.bundleID))] = { behavior = \(behavior), width = \(width) },"
            }
        return "-- Written by RibbonDesk App Behavior.\nreturn {\n" + entries.joined(separator: "\n") + "\n}\n"
    }
}

struct AppBehaviorStore {
    let directory: URL
    var json: URL { directory.appendingPathComponent("app-behavior.json") }
    var lua: URL { directory.appendingPathComponent("app-behavior.lua") }

    func read() throws -> AppBehaviorData {
        guard FileManager.default.fileExists(atPath: json.path) else { return AppBehaviorData() }
        var value = try JSONDecoder().decode(AppBehaviorData.self, from: Data(contentsOf: json))
        value.history = Array(value.history.prefix(AppBehaviorData.historyLimit))
        // A malformed catalog must not silently produce competing engine rules.
        guard Set(value.apps.map(\.bundleID)).count == value.apps.count,
            value.apps.allSatisfy({ !$0.bundleID.isEmpty })
        else { throw StoreError.invalidCatalog }
        return value
    }

    /// Keep the editable catalog and its engine export consistent on failure.
    func write(_ value: AppBehaviorData, reload: () throws -> Void = {}) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for file in [json, lua] where fm.fileExists(atPath: file.path) {
            let attrs = try fm.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                (attrs[.referenceCount] as? NSNumber)?.intValue == 1
            else { throw StoreError.unsafeFile }
        }
        let oldJSON = try fm.fileExists(atPath: json.path) ? Data(contentsOf: json) : nil
        let oldLua = try fm.fileExists(atPath: lua.path) ? Data(contentsOf: lua) : nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(value).write(to: json, options: .atomic)
            try Data(value.luaSource.utf8).write(to: lua, options: .atomic)
            for file in [json, lua] { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            if oldLua != Data(value.luaSource.utf8) { try reload() }
        } catch {
            for (file, old) in [(json, oldJSON), (lua, oldLua)] {
                if let old {
                    try? old.write(to: file, options: .atomic)
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                } else {
                    try? fm.removeItem(at: file)
                }
            }
            throw error
        }
    }

    private enum StoreError: LocalizedError {
        case invalidCatalog, unsafeFile
        var errorDescription: String? {
            switch self {
            case .invalidCatalog: return "The App Behavior catalog contains missing or duplicate app identifiers."
            case .unsafeFile: return "App Behavior files must be regular, private files."
            }
        }
    }
}

struct AppBehaviorEvent: Decodable, Sendable {
    let event: String
    let window_id: Int32
    let pid: Int32
    let app_name: String
    let bundle_id: String
    let floating: Bool
    let startup: Bool?
    var key: String { "\(pid):\(window_id)" }

    private enum CodingKeys: String, CodingKey {
        case event, window_id, pid, app_name, bundle_id, floating, startup
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        event = try values.decode(String.self, forKey: .event)
        window_id = try values.decode(Int32.self, forKey: .window_id)
        if event == "window_unavailable" {
            pid = 0
            app_name = ""
            bundle_id = ""
            floating = true
            startup = nil
        } else {
            pid = try values.decode(Int32.self, forKey: .pid)
            app_name = try values.decode(String.self, forKey: .app_name)
            bundle_id = try values.decode(String.self, forKey: .bundle_id)
            floating = try values.decode(Bool.self, forKey: .floating)
            startup = try values.decodeIfPresent(Bool.self, forKey: .startup)
        }
    }
}

/// Only lifecycle and explicit membership events cross to the companion UI.
final class AppBehaviorEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func consume(_ data: Data) -> [AppBehaviorEvent] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        guard buffer.count <= 4 * 1024 * 1024 else {
            buffer.removeAll()
            return []
        }
        var events: [AppBehaviorEvent] = []
        while let newline = buffer.firstIndex(of: 10) {
            if let value = try? JSONDecoder().decode(AppBehaviorEvent.self, from: buffer[..<newline]),
                ["window_opened", "window_behavior_changed", "window_unavailable"].contains(value.event)
            {
                events.append(value)
            }
            buffer.removeSubrange(...newline)
        }
        return events
    }
}
