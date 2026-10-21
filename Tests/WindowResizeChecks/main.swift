import Foundation
import RibbonCore

enum SizingFailure: Error { case refused, minimum }

@MainActor
final class OffscreenSizingModel {
    var frame: Frame
    let viewport: Frame
    var minimumWidth = 0.0
    var operations: [String] = []
    init(frame: Frame, viewport: Frame) { self.frame = frame; self.viewport = viewport }
    func move(_ target: Frame) {
        operations.append("move")
        frame.x = target.x; frame.y = target.y
    }
    func resize(_ target: Frame) throws {
        operations.append("size")
        // Model the observed distinction: native sizing can reject a parked
        // resize even though exactly that size works at an onscreen origin.
        guard frame.x >= viewport.x, frame.maxX <= viewport.maxX,
              target.x >= viewport.x, target.maxX <= viewport.maxX else { throw SizingFailure.refused }
        frame.width = max(minimumWidth, target.width); frame.height = target.height
        guard abs(frame.width - target.width) <= 6 else { throw SizingFailure.minimum }
    }
}

@main
struct WindowResizeChecks {
    @MainActor static func main() async {
        var assertions = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            assertions += 1
            if !value { failures += 1; print("FAIL \(message)") }
        }
        let viewport = Frame(x: 0, y: 25, width: 1856, height: 1055)
        let original = Frame(x: 0, y: 115, width: 1856, height: 875)
        let parked = Frame(x: -919, y: 25, width: 924, height: 1055)
        let stage = WindowResizePolicy.stagingFrame(current: original, target: parked, viewport: viewport)
        check(stage == Frame(x: 0, y: 25, width: 1856, height: 875), "visible original resizes before parking")
        check(WindowResizePolicy.stagingFrame(current: parked, target: parked, viewport: viewport) == nil,
              "position-only gesture geometry requires no staging")
        check(WindowResizePolicy.stagingFrame(current: original,
            target: Frame(x: 0, y: 25, width: 924, height: 1055), viewport: viewport) == nil,
              "visible destination keeps normal move/resize path")
        check(WindowResizePolicy.stagingFrame(current: original,
            target: Frame(x: -5, y: 25, width: 1900, height: 1055), viewport: viewport) == nil,
              "oversized target cannot stage across another display")
        check(WindowResizePolicy.stagingFrame(current: Frame(x: 0, y: 25, width: 1900, height: 1055),
            target: parked, viewport: viewport) == nil, "oversized current cannot silently stage")
        check(WindowResizePolicy.stagingFrame(current: original,
            target: Frame(x: .nan, y: 25, width: 924, height: 1055), viewport: viewport) == nil,
              "nonfinite geometry refused")

        for x in [-1640.25, 0.0, 417.5] {
            for y in [-900.5, 25.0, 1080.25] {
                let view = Frame(x: x, y: y, width: 1856, height: 1055)
                for side in [-1.0, 1.0] {
                    let current = Frame(x: x + side * 1851, y: y + 100, width: 1856, height: 875)
                    let target = Frame(x: side < 0 ? x - 919 : view.maxX - 5,
                                       y: y, width: 924, height: 1055)
                    let safe = WindowResizePolicy.stagingFrame(current: current, target: target, viewport: view)
                    check(safe != nil, "both parking edges stage with fractional display origins")
                    if let safe {
                        check(safe.x >= view.x && safe.maxX <= view.maxX && safe.y >= view.y && safe.maxY <= view.maxY,
                              "current stage remains wholly in owning display")
                        check(safe.x + target.width <= view.maxX && safe.y + target.height <= view.maxY,
                              "requested resized stage remains wholly in owning display")
                    }
                }
            }
        }
        do {
            let control = OffscreenSizingModel(frame: original, viewport: viewport)
            control.move(parked)
            do { try control.resize(parked); check(false, "negative control rejects parked sizing") }
            catch { check(control.frame.width == original.width, "negative control reproduces false wide result") }

            for startingFrame in [original, Frame(x: -1851, y: 25, width: 1856, height: 1055)] {
                let model = OffscreenSizingModel(frame: startingFrame, viewport: viewport)
                let prepared = try await WindowResizeStaging.prepare(current: model.frame, target: parked, viewport: viewport,
                    moveTo: { model.move($0) }, resizeTo: { try model.resize($0) })
                model.move(parked)
                check(prepared && model.frame == parked, "production stage executor preserves requested half width")
                check(model.operations == ["move", "size", "move"], "resize finishes safely before final park")
            }

            let constrained = OffscreenSizingModel(frame: original, viewport: viewport)
            constrained.minimumWidth = 1000
            do {
                _ = try await WindowResizeStaging.prepare(current: constrained.frame, target: parked, viewport: viewport,
                    moveTo: { constrained.move($0) }, resizeTo: { try constrained.resize($0) })
                constrained.move(parked)
                check(false, "genuine native minimum must propagate")
            } catch SizingFailure.minimum {
                check(constrained.frame.width == 1000 && constrained.frame.x == viewport.x,
                      "true size constraint observed at safe origin")
                check(constrained.operations == ["move", "size"], "no final park follows failed safe resize")
            }

            var resizeAfterMoveFailure = false
            do {
                _ = try await WindowResizeStaging.prepare(current: original, target: parked, viewport: viewport,
                    moveTo: { _ in throw SizingFailure.refused }, resizeTo: { _ in resizeAfterMoveFailure = true })
                check(false, "staging failure must propagate")
            } catch { check(!resizeAfterMoveFailure, "failed stage cannot continue to sizing") }

            var resizedAfterCancellation = false
            let cancelled = Task { @MainActor in
                try await WindowResizeStaging.prepare(current: original, target: parked, viewport: viewport,
                    moveTo: { _ in withUnsafeCurrentTask { $0?.cancel() } },
                    resizeTo: { _ in resizedAfterCancellation = true })
            }
            do { _ = try await cancelled.value; check(false, "cancelled stage must abort") }
            catch is CancellationError { check(!resizedAfterCancellation, "cancellation between move and size stops sizing") }

            var unnecessaryOperations = 0
            let skipped = try await WindowResizeStaging.prepare(current: parked, target: parked, viewport: viewport,
                moveTo: { _ in unnecessaryOperations += 1 }, resizeTo: { _ in unnecessaryOperations += 1 })
            check(!skipped && unnecessaryOperations == 0, "position-only work invokes no staging operations")
        } catch { check(false, "unexpected sizing error: \(error)") }
        print("\(assertions) window resize assertions; \(failures) failures. Pure policy/injected sizing; no AX, native windows, input, or preferences accessed.")
        if failures > 0 { exit(1) }
    }
}
