import AppKit

func window(_ id: Int32) -> RibbonWindow {
    RibbonWindow(window_id: id, bundle_id: "fixture", app_name: "Fixture", title: "Preview", focused: false,
                 floating: false, visible: false, frame: nil,
                 ribbon_frame: .init(x: Double(id) * 604, y: 0, width: 600, height: 800))
}
func bitmap() -> CGImage {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 16, bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)!.cgImage!
}
@MainActor
final class Source: RibbonScreenshotSource {
    var calls: [Int32] = []
    var active = 0
    var peak = 0
    var preparations = 0
    func prepare() async throws {
        preparations += 1
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    func image(for id: Int32, width: Int, height: Int) async throws -> CGImage? {
        precondition(max(width, height) <= 1024)
        calls.append(id); active += 1; peak = max(peak, active)
        defer { active -= 1 }
        // Deliberately ignore cancellation: the session guard must reject stale results.
        try? await Task.sleep(nanoseconds: 20_000_000)
        return bitmap()
    }
}
var done = false
Task { @MainActor in
    let sample = bitmap()
    let imageCost = sample.bytesPerRow * sample.height
    let cache = RibbonPreviewCache(limit: imageCost * 2)
    for id: Int32 in [1, 2] { cache.insert(sample, for: .init(window(id))) }
    precondition(cache.image(for: .init(window(1))) != nil)
    cache.insert(sample, for: .init(window(3)))
    precondition(cache.image(for: .init(window(2))) == nil, "Evict the least recently used image")
    precondition(cache.cost <= cache.limit)
    cache.insert(sample, for: .init(window(3)))
    precondition(cache.cost == imageCost * 2, "Replacing an entry must not double count cost")

    let source = Source()
    let manager = RibbonPreviewCapture(source: { source })
    let windows = (1...100).map { window(Int32($0)) }
    let frames = manager.begin(windows: windows)
    var failures = 0
    @MainActor func request(_ targets: [RibbonWindow]) {
        manager.request(windows: targets, frames: frames, scale: 0.5, backingScale: 2) { _ in failures += 1 }
    }
    request(Array(windows.prefix(30)))
    // Pan before enumeration completes: obsolete queued work should be discarded.
    request(Array(windows.suffix(3)))
    try? await Task.sleep(nanoseconds: 120_000_000)
    precondition(Set(source.calls) == Set([98, 99, 100]), "Capture only the most recent visible region")
    precondition(source.peak == 2 && source.active == 0, "At most two snapshots in flight")
    precondition(source.preparations == 1)
    precondition(failures == 0 && frames[100]?.image != nil && frames[1]?.image == nil)
    request(Array(windows.suffix(3)))
    try? await Task.sleep(nanoseconds: 40_000_000)
    precondition(source.calls.count == 3, "Visible previews stay frozen without repeated capture")
    manager.stop()
    let warm = manager.begin(windows: windows)
    precondition(warm[100]?.image != nil, "Reopening reuses snapshots immediately")
    manager.request(windows: Array(windows.prefix(3)), frames: warm, scale: 0.5, backingScale: 2) { _ in failures += 1 }
    try? await Task.sleep(nanoseconds: 30_000_000)
    manager.stop()
    try? await Task.sleep(nanoseconds: 60_000_000)
    precondition(warm[1]?.image == nil, "Late results cannot update a closed session")
    precondition(failures == 0)
    done = true
}
let deadline = Date().addingTimeInterval(5)
while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
precondition(done, "Snapshot checks timed out")
print("Snapshot capture: two-request limit, visible-only queue replacement, freeze, warm cache, byte budget, and cancellation passed")
