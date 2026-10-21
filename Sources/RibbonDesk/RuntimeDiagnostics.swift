import Foundation

/// Explicit, bounded local timing capture. Normal operation records nothing.
/// Rows contain event/geometry timing and IDs, never titles or document text.
final class RuntimeDiagnostics: @unchecked Sendable {
    static let shared = RuntimeDiagnostics()
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "RibbonDesk.diagnostics", qos: .utility)
    private var rows: [[String: Any]] = []
    private var capturing = false
    private var deadline = 0.0
    private var generation: UInt = 0
    private let destination: URL
    var location: String { destination.path }
    var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return capturing && ProcessInfo.processInfo.systemUptime < deadline
    }
    init(destination: URL? = nil, allowLaunchMarker: Bool = true) {
        let bundle = Bundle.main.bundleIdentifier ?? "local.prototype.RibbonDesk.diagnostics-tests"
        self.destination = destination ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundle).appendingPathComponent("input-motion-diagnostics.json")
        let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if allowLaunchMarker, Bundle.main.bundleIdentifier == "local.prototype.RibbonDesk",
           FileManager.default.fileExists(atPath: root.appendingPathComponent(".build/trace-input.enabled").path) {
            startCapture()
        }
    }
    func startCapture(seconds: TimeInterval = 60) {
        let duration = seconds.isFinite ? max(0.1, min(60, seconds)) : 60
        lock.lock()
        generation &+= 1; let token = generation
        rows.removeAll(keepingCapacity: true)
        deadline = ProcessInfo.processInfo.systemUptime + duration; capturing = true
        lock.unlock()
        record("capture-start", ["seconds": duration])
        writer.asyncAfter(deadline: .now() + duration) { [weak self] in self?.stopCapture(generation: token) }
    }
    func stopCapture() { stopCapture(generation: nil) }
    private func stopCapture(generation expected: UInt?) {
        lock.lock()
        guard capturing, expected == nil || expected == generation else { lock.unlock(); return }
        capturing = false
        rows.append(["kind": "capture-stop", "clock": ProcessInfo.processInfo.systemUptime])
        if rows.count > 4000 { rows.removeFirst(rows.count - 4000) }
        let copy = rows
        lock.unlock()
        write(copy)
    }
    func record(_ kind: String, _ values: [String: Any]) {
        lock.lock()
        guard capturing else { lock.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now < deadline else {
            capturing = false; let copy = rows; lock.unlock(); write(copy); return
        }
        var row = values; row["kind"] = kind; row["clock"] = now
        rows.append(row)
        if rows.count > 4000 { rows.removeFirst(rows.count - 4000) }
        lock.unlock()
    }
    func flush() {
        lock.lock(); let copy = rows; lock.unlock()
        guard !copy.isEmpty else { return }
        write(copy)
    }
    private func write(_ copy: [[String: Any]]) {
        let url = destination
        writer.async {
            guard let data = try? JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys]) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try? data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
