import AppKit
import ScreenCaptureKit
import CoreImage
import CoreMedia

@MainActor
final class RibbonPreviewFrame: ObservableObject {
    @Published var image: CGImage?
}

/// Bound the warm cache by decoded image cost, rather than window count.
@MainActor
final class RibbonPreviewCache {
    struct Key: Hashable {
        let id: Int32
        let bundle: String
        let width: Double
        let height: Double
        init(_ window: RibbonWindow) {
            id = window.id; bundle = window.bundle_id
            width = (window.ribbon_frame ?? window.frame)?.width ?? 900
            height = (window.ribbon_frame ?? window.frame)?.height ?? 700
        }
    }
    private struct Entry { let image: CGImage; let cost: Int; var used: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var cost = 0
    let limit: Int
    init(limit: Int = 64 * 1024 * 1024) { self.limit = limit }
    func image(for key: Key) -> CGImage? {
        clock &+= 1
        entries[key]?.used = clock
        return entries[key]?.image
    }
    func insert(_ image: CGImage, for key: Key) {
        cost -= entries.removeValue(forKey: key)?.cost ?? 0
        let bytes = image.bytesPerRow * image.height
        guard bytes <= limit else { return }
        while cost + bytes > limit, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            cost -= entries.removeValue(forKey: oldest)!.cost
        }
        clock &+= 1
        entries[key] = Entry(image: image, cost: bytes, used: clock)
        cost += bytes
    }
}

@MainActor
protocol RibbonScreenshotSource: AnyObject {
    func prepare() async throws
    func image(for id: Int32, width: Int, height: Int) async throws -> CGImage?
}

@MainActor
private final class SystemRibbonScreenshotSource: RibbonScreenshotSource {
    private var windows: [Int32: SCWindow] = [:]
    func prepare() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        windows = Dictionary(content.windows.map { (Int32(bitPattern: $0.windowID), $0) }, uniquingKeysWith: { first, _ in first })
    }
    func image(for id: Int32, width: Int, height: Int) async throws -> CGImage? {
        guard let window = windows[id] else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = width; configuration.height = height
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        if #available(macOS 14.0, *) {
            configuration.ignoreShadowsSingleWindow = true
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
        // macOS 13 has no screenshot manager. Take just one complete frame,
        // with a timeout, then immediately stop the temporary stream.
        return try await RibbonSingleFrameCapture().image(filter: filter, configuration: configuration)
    }
}

private final class RibbonSingleFrameCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "local.paneru.overview.snapshot", qos: .userInitiated)
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Error>?
    private var finished = false
    @MainActor
    func image(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage? {
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: Self.queue)
        do {
            let image: CGImage? = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    install(continuation)
                    Task {
                        do {
                            try await stream.startCapture()
                            if isFinished() { try? await stream.stopCapture() }
                        }
                        catch { finish(.failure(error)) }
                    }
                    Self.queue.asyncAfter(deadline: .now() + 1) { self.finish(.success(nil)) }
                }
            } onCancel: { self.finish(.failure(CancellationError())) }
            try? await stream.stopCapture()
            return image
        } catch {
            try? await stream.stopCapture()
            throw error
        }
    }
    private func install(_ value: CheckedContinuation<CGImage?, Error>) {
        lock.lock()
        let cancelled = finished
        if !cancelled { continuation = value }
        lock.unlock()
        if cancelled { value.resume(throwing: CancellationError()) }
    }
    private func finish(_ result: Result<CGImage?, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let value = continuation; continuation = nil
        lock.unlock()
        value?.resume(with: result)
    }
    private func isFinished() -> Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func stream(_ stream: SCStream, didStopWithError error: Error) { finish(.failure(error)) }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let metadata = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = metadata.first?[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
              let pixels = buffer.imageBuffer else { return }
        guard !isFinished() else { return }
        let source = CIImage(cvPixelBuffer: pixels)
        finish(.success(Self.context.createCGImage(source, from: source.extent)))
    }
}

/// At most two one-shot requests at a time, only for the visible ribbon region.
/// Each window freezes after its first result in this session. Reopening can
/// reuse the bounded memory cache immediately while fresh snapshots arrive.
@MainActor
final class RibbonPreviewCapture {
    private struct Job { let key: RibbonPreviewCache.Key; let frame: RibbonPreviewFrame; let width: Int; let height: Int }
    private let cache: RibbonPreviewCache
    private let makeSource: () -> RibbonScreenshotSource
    private var source: RibbonScreenshotSource?
    private var prepared = false
    private var attempted = Set<Int32>()
    private var completed = Set<Int32>()
    private var queue: [Job] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(cache: RibbonPreviewCache? = nil, source: (() -> RibbonScreenshotSource)? = nil) {
        self.cache = cache ?? RibbonPreviewCache()
        makeSource = source ?? { SystemRibbonScreenshotSource() }
    }
    func begin(windows: [RibbonWindow]) -> [Int32: RibbonPreviewFrame] {
        stop()
        source = makeSource()
        return Dictionary(uniqueKeysWithValues: windows.map { ($0.id, frame(for: $0)) })
    }
    func frame(for window: RibbonWindow) -> RibbonPreviewFrame {
        let frame = RibbonPreviewFrame()
        frame.image = cache.image(for: .init(window))
        return frame
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        queue.removeAll(); attempted.removeAll(); completed.removeAll(); source = nil; prepared = false
    }
    func request(windows: [RibbonWindow], frames: [Int32: RibbonPreviewFrame], scale: Double, backingScale: Double,
                 failure: @escaping (String) -> Void) {
        guard let source else { return }
        let visible = Set(windows.map(\.id))
        for (id, frame) in frames where !visible.contains(id) && frame.image != nil { frame.image = nil }
        for window in windows {
            guard let frame = frames[window.id], frame.image == nil else { continue }
            frame.image = cache.image(for: .init(window))
            // A far-away preview evicted from the bounded cache may be captured again.
            if frame.image == nil, completed.remove(window.id) != nil { attempted.remove(window.id) }
        }
        // Replace queued work after a pan so a fast scroll cannot build a backlog.
        queue = windows.compactMap { window in
            guard !attempted.contains(window.id), let frame = frames[window.id] else { return nil }
            let key = RibbonPreviewCache.Key(window)
            let ratio = min(1, 1024 / max(1, max(key.width, key.height) * scale * backingScale)) * scale * backingScale
            return Job(key: key, frame: frame, width: max(1, Int(key.width * ratio)), height: max(1, Int(key.height * ratio)))
        }
        guard task == nil, !queue.isEmpty else { return }
        let token = generation
        task = Task {
            do {
                if !prepared { try await source.prepare() }
                guard generation == token, !Task.isCancelled else { return }
                prepared = true
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<2 {
                        group.addTask { @MainActor in
                            while self.generation == token, !Task.isCancelled, !self.queue.isEmpty {
                                let job = self.queue.removeFirst()
                                guard self.attempted.insert(job.key.id).inserted else { continue }
                                do {
                                    let image = try await source.image(for: job.key.id, width: job.width, height: job.height)
                                    guard self.generation == token, !Task.isCancelled else { return }
                                    if let image {
                                        self.cache.insert(image, for: job.key)
                                        job.frame.image = image
                                        self.completed.insert(job.key.id)
                                    }
                                } catch {
                                    guard self.generation == token, !Task.isCancelled else { return }
                                    failure("Some previews are unavailable. Protected content may be blank.")
                                }
                            }
                        }
                    }
                }
            } catch {
                if generation == token, !Task.isCancelled { failure("Previews unavailable. Check Screen Recording access, then reopen.") }
            }
            if generation == token { task = nil }
        }
    }
}
