import AppKit
import Darwin
import RibbonCore

struct DisplayInfo: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let frame: Frame
    let usable: Frame

    static func current(_ screens: [NSScreen]) -> [DisplayInfo] {
        // AX/CG use the top of the primary display, including for displays above
        // or to the left of it. Each display's own maxY is not the global origin.
        let top = screens.first?.frame.maxY ?? 0
        return screens.map { screen in
            func ax(_ r: NSRect) -> Frame {
                Frame(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
            }
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return DisplayInfo(id: number?.stringValue ?? screen.localizedName, name: screen.localizedName,
                               frame: ax(screen.frame), usable: ax(screen.visibleFrame))
        }
    }

    static func owner(of window: Frame, among displays: [DisplayInfo]) -> DisplayInfo? {
        displays.max { window.intersectionArea($0.frame) < window.intersectionArea($1.frame) }
    }
}

extension Frame {
    func contains(_ point: CGPoint) -> Bool {
        point.x >= x && point.x < maxX && point.y >= y && point.y < maxY
    }
    func intersectionArea(_ other: Frame) -> Double {
        max(0, min(maxX, other.maxX) - max(x, other.x)) *
            max(0, min(maxY, other.maxY) - max(y, other.y))
    }
}

struct WindowAccount: Codable, Identifiable {
    let id: String
    let app: String
    let title: String
    let reason: String
    let frame: Frame?
}

struct SavedWindow: Codable {
    let id: String
    let number: UInt32
    let pid: Int32
    let launchDate: Date?
    let bundleID: String?
    let appName: String
    let title: String
    let original: Frame
    let originalSpaces: [UInt64]?
    let stagedFromOtherDesktop: Bool?
    let preservesDesktop: Bool?
    let capturedAt: Date?

    init(_ window: ManagedWindow) {
        id = window.id; number = window.number; pid = window.pid
        let app = NSRunningApplication(processIdentifier: window.pid)
        launchDate = app?.launchDate; bundleID = app?.bundleIdentifier
        appName = window.appName; title = window.title; original = window.original
        originalSpaces = window.originalSpaces.isEmpty ? nil : window.originalSpaces
        stagedFromOtherDesktop = window.stagedFromOtherDesktop ? true : nil
        preservesDesktop = window.preservesDesktop ? true : nil
        capturedAt = Date()
    }
}

enum RecoveryIdentity {
    /// Geometry alone can be ambiguous when several overflow windows share a
    /// parking position. A unique unchanged title can disambiguate that set.
    static func candidate(titles: [String], savedTitle: String) -> Int? {
        if titles.count == 1 { return 0 }
        let matches = titles.indices.filter { titles[$0] == savedTitle }
        return matches.count == 1 ? matches[0] : nil
    }
}

enum ProcessIdentity {
    static func startTime(_ pid: pid_t) -> Date? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size else { return nil }
        let time = info.kp_proc.p_un.__p_starttime
        guard time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }

    static func matches(savedLaunch: Date?, currentLaunch: Date?, kernelStart: Date?, capturedAt: Date) -> Bool {
        if let savedLaunch, let currentLaunch {
            return abs(currentLaunch.timeIntervalSince(savedLaunch)) < 0.01
        }
        // Finder can have no AppKit launchDate. A process that started after
        // capture is a reused PID and must never inherit the saved CG window.
        guard let start = kernelStart ?? currentLaunch else { return false }
        return start <= capturedAt
    }
}

struct SessionSnapshot: Codable {
    let version: Int
    let id: UUID
    let savedAt: Date
    let displays: [DisplayInfo]
    var windows: [SavedWindow]
    let unchanged: [WindowAccount]
    var pending: Set<String>
    var restoredAt: Date?

    init(displays: [DisplayInfo], windows: [ManagedWindow], unchanged: [WindowAccount]) {
        version = 1; id = UUID(); savedAt = Date()
        self.displays = displays; self.windows = windows.map(SavedWindow.init)
        self.unchanged = unchanged; pending = Set(windows.map(\.id))
    }
}

@MainActor
protocol SessionPersisting: AnyObject {
    var location: String { get }
    func load() throws -> SessionSnapshot?
    func save(_ snapshot: SessionSnapshot) throws
}

@MainActor
final class SessionStore: SessionPersisting {
    let url: URL
    var location: String { url.path }
    init(url: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.url = url ?? base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.prototype.RibbonDesk")
            .appendingPathComponent("original-arrangement.json")
    }
    func load() throws -> SessionSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 1 else { throw WindowControlError.message("Unknown arrangement snapshot version. The existing snapshot was preserved.") }
        return snapshot
    }
    func save(_ snapshot: SessionSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
