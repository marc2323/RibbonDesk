import Foundation
import RibbonCore

/// Settled resizing must not infer an app minimum from a resize constrained by
/// an almost-offscreen destination. Both sizes must fit the owning viewport.
enum WindowResizePolicy {
    static func stagingFrame(current: Frame, target: Frame, viewport: Frame) -> Frame? {
        guard current.isUsable, target.isUsable, viewport.isUsable,
              abs(current.width - target.width) > 1 || abs(current.height - target.height) > 1,
              target.x < viewport.x - 0.5 || target.maxX > viewport.maxX + 0.5 else { return nil }
        let width = max(current.width, target.width)
        let height = max(current.height, target.height)
        guard width <= viewport.width, height <= viewport.height else { return nil }
        return Frame(x: max(viewport.x, min(viewport.maxX - width, current.x)),
                     y: max(viewport.y, min(viewport.maxY - height, current.y)),
                     width: current.width, height: current.height)
    }
}

/// The same ordered plan drives native AX and injected sizing checks. The
/// caller validates each operation before the destination can be parked.
enum WindowResizeStaging {
    @MainActor
    static func prepare(current: Frame, target: Frame, viewport: Frame,
                        moveTo: (Frame) async throws -> Void,
                        resizeTo: (Frame) async throws -> Void) async throws -> Bool {
        guard let stage = WindowResizePolicy.stagingFrame(current: current, target: target, viewport: viewport) else { return false }
        try Task.checkCancellation()
        try await moveTo(stage)
        try Task.checkCancellation()
        try await resizeTo(Frame(x: stage.x, y: stage.y, width: target.width, height: target.height))
        try Task.checkCancellation()
        return true
    }
}
