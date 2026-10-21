import Foundation

final class MotionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
    }
}

/// A frame contains one ordered stream per application. Different applications
/// may service AX concurrently; an application's own stream never overlaps.
/// The controller supplies only its latest frame while one barrier is in flight.
final class MotionBatchTransport: @unchecked Sendable {
    struct Operation: @unchecked Sendable {
        let id: String
        let body: () throws -> Void
        init(_ id: String, _ body: @escaping () throws -> Void) { self.id = id; self.body = body }
    }
    struct Work: @unchecked Sendable {
        let pid: pid_t
        var positions: [Operation] = []
        var raises: [Operation] = []
    }
    struct LocalWork: @unchecked Sendable {
        var positions: [Operation] = []
        var raises: [Operation] = []
    }
    private final class Lane {
        let queue: DispatchQueue
        let animations: MotionAppAnimations
        var prepared = false // confined to this lane's queue
        init(pid: pid_t, animations: MotionAppAnimations) {
            queue = DispatchQueue(label: "RibbonDesk.motion.pid-\(pid)", qos: .userInteractive)
            self.animations = animations
        }
    }
    private final class BatchState: @unchecked Sendable {
        private let lock = NSLock()
        private var firstError: Error?
        private var firstStarts: [pid_t: Double] = [:]
        private var lastEnds: [pid_t: Double] = [:]
        func failed(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            if firstError == nil { firstError = error }
        }
        func began(pid: pid_t, at time: Double) {
            lock.lock(); defer { lock.unlock() }
            if firstStarts[pid] == nil { firstStarts[pid] = time }
        }
        func ended(pid: pid_t, at time: Double) {
            lock.lock(); lastEnds[pid] = time; lock.unlock()
        }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return firstError }
        var metrics: [String: Any] {
            lock.lock(); defer { lock.unlock() }
            let starts = Array(firstStarts.values), ends = Array(lastEnds.values)
            return ["startSkewMS": ((starts.max() ?? 0) - (starts.min() ?? 0)) * 1000,
                    "finishSkewMS": ((ends.max() ?? 0) - (ends.min() ?? 0)) * 1000,
                    "writeSpanMS": ((ends.max() ?? 0) - (starts.min() ?? 0)) * 1000,
                    "lanes": starts.count]
        }
    }
    private let coordinator = DispatchQueue(label: "RibbonDesk.motion.barrier", qos: .userInteractive)
    private let admission = NSLock()
    private var latestID: UInt64 = 0
    private var lanes: [pid_t: Lane] = [:] // coordinator only
    private let animationFactory: () -> MotionAppAnimations
    private let trace: (String, [String: Any]) -> Void

    init(animationFactory: @escaping () -> MotionAppAnimations = { MotionAppAnimations() },
         trace: @escaping (String, [String: Any]) -> Void = { _, _ in }) {
        self.animationFactory = animationFactory; self.trace = trace
    }

    private func admit() -> UInt64 {
        admission.lock(); defer { admission.unlock() }
        latestID &+= 1; return latestID
    }
    private func isLatest(_ id: UInt64) -> Bool {
        admission.lock(); defer { admission.unlock() }; return id == latestID
    }
    private func lane(for pid: pid_t) -> Lane {
        if let existing = lanes[pid] { return existing }
        let lane = Lane(pid: pid, animations: animationFactory()); lanes[pid] = lane
        return lane
    }

    func perform(_ work: [Work], local: LocalWork = LocalWork()) async throws {
        let id = admit(), queuedAt = ProcessInfo.processInfo.systemUptime
        trace("motion-batch-queued", ["batch": id])
        let cancellation = MotionCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                coordinator.async {
                    do {
                        try cancellation.check()
                        // A cancelled gesture may have submitted a newer frame
                        // before a slow native call returned. Never replay any
                        // superseded queued frame when that barrier opens.
                        guard self.isLatest(id) else { throw CancellationError() }
                        try self.run(work, local: local, id: id, queuedAt: queuedAt,
                                     cancellation: cancellation)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    private func run(_ work: [Work], local: LocalWork, id: UInt64, queuedAt: Double,
                     cancellation: MotionCancellation) throws {
        let start = ProcessInfo.processInfo.systemUptime
        let state = BatchState(), group = DispatchGroup()
        trace("motion-batch-start", ["batch": id, "queueMS": (start - queuedAt) * 1000,
                                    "apps": work.count])
        for request in work {
            let lane = lane(for: request.pid)
            group.enter()
            lane.queue.async {
                defer { group.leave() }
                let began = ProcessInfo.processInfo.systemUptime
                do {
                    try cancellation.check()
                    if !lane.prepared, !request.positions.isEmpty {
                        lane.prepared = lane.animations.prepare(request.pid)
                    }
                    try self.operations(request.positions, phase: "position", pid: request.pid,
                                        id: id, cancellation: cancellation, state: state)
                    // Boundary-only raises share the lane and frame barrier;
                    // another app's slow position does not postpone this lane.
                    try self.operations(request.raises, phase: "raise", pid: request.pid,
                                        id: id, cancellation: cancellation, state: state)
                } catch { state.failed(error) }
                self.trace("motion-lane", ["batch": id, "pid": request.pid,
                    "ms": (ProcessInfo.processInfo.systemUptime - began) * 1000])
            }
        }
        if !local.positions.isEmpty || !local.raises.isEmpty {
            group.enter()
            DispatchQueue.main.async {
                defer { group.leave() }
                do {
                    try self.operations(local.positions, phase: "position", pid: getpid(),
                                        id: id, cancellation: cancellation, state: state)
                    try self.operations(local.raises, phase: "raise", pid: getpid(),
                                        id: id, cancellation: cancellation, state: state)
                } catch { state.failed(error) }
            }
        }
        group.wait()
        // Cancellation never returns while an uninterruptible AX call remains
        // outstanding. Recovery/resize therefore cannot overtake that call.
        let error: Error?
        do { try cancellation.check(); error = state.error } catch let stopped { error = stopped }
        if error != nil { resetLanes() }
        var metrics = state.metrics
        metrics["batch"] = id; metrics["ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        metrics["failed"] = error != nil
        trace("motion-batch", metrics)
        if let error { throw error }
    }

    private func operations(_ operations: [Operation], phase: String, pid: pid_t, id: UInt64,
                            cancellation: MotionCancellation, state: BatchState) throws {
        for operation in operations {
            try cancellation.check()
            let start = ProcessInfo.processInfo.systemUptime
            if phase == "position" { state.began(pid: pid, at: start) }
            trace("motion-operation-begin", ["batch": id, "pid": pid,
                  "window": operation.id, "phase": phase])
            do {
                try autoreleasepool { try operation.body() }
                let end = ProcessInfo.processInfo.systemUptime
                if phase == "position" { state.ended(pid: pid, at: end) }
                trace("motion-operation-end", ["batch": id, "pid": pid,
                      "window": operation.id, "phase": phase, "ms": (end - start) * 1000,
                      "failed": false])
            } catch {
                let end = ProcessInfo.processInfo.systemUptime
                if phase == "position" { state.ended(pid: pid, at: end) }
                trace("motion-operation-end", ["batch": id, "pid": pid,
                      "window": operation.id, "phase": phase, "ms": (end - start) * 1000,
                      "failed": true])
                throw error
            }
        }
    }

    /// Runs only after every previously submitted frame and all its lanes finish.
    /// A failed flag restoration remains owed and is retried by the next drain.
    func drain() async {
        await withCheckedContinuation { continuation in
            coordinator.async { self.resetLanes(); continuation.resume() }
        }
    }
    private func resetLanes() {
        let group = DispatchGroup()
        for lane in lanes.values {
            group.enter()
            lane.queue.async {
                lane.animations.reset(); lane.prepared = false; group.leave()
            }
        }
        group.wait()
    }
}
