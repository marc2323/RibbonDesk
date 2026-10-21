import Foundation
import Darwin

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var traces: [(String, [String: Any])] = []
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func record(_ kind: String, _ values: [String: Any]) {
        lock.lock(); traces.append((kind, values)); lock.unlock()
    }
    func rows(_ kind: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }; return traces.filter { $0.0 == kind }.map(\.1)
    }
}

@main
struct MotionTransportChecks {
    private static var assertions = 0, failures = 0
    private static func expect(_ value: Bool, _ message: String) {
        assertions += 1
        if !value { failures += 1; print("FAIL \(message)") }
    }
    private static func wait(_ semaphore: DispatchSemaphore) async -> Bool {
        await Task.detached { semaphore.wait(timeout: .now() + 2) == .success }.value
    }
    private static func until(_ predicate: @escaping () -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return predicate()
    }
    private static func transport(log: Log = Log()) -> MotionBatchTransport {
        MotionBatchTransport(animationFactory: {
            MotionAppAnimations(read: { _ in .enabled(false) }, write: { _, _ in false })
        }, trace: log.record)
    }
    enum Failure: Error { case expected, timeout }

    static func main() async {
        await concurrentApplications()
        await sameApplicationOrder()
        await sessionAnimationLease()
        await transientAnimationReadRetries()
        await errorAndRestorationDebt()
        await cancellationDrainsAllNativeCalls()
        await localMainAndRaiseOrder()
        await obsoleteQueuedFrames()
        print("\(assertions) motion transport assertions; \(failures) failures. Injected work only; no native AX, OS input, windows, or preferences accessed.")
        exit(failures == 0 ? 0 : 1)
    }

    private static func concurrentApplications() async {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let fast = DispatchSemaphore(value: 0), log = Log(), executor = transport()
        let batch = Task {
            try await executor.perform([
                .init(pid: 11, positions: [.init("slow") {
                    log.append("slow-start"); entered.signal()
                    guard release.wait(timeout: .now() + 2) == .success else { throw Failure.timeout }
                    log.append("slow-end")
                }]),
                .init(pid: 22, positions: [.init("fast") { log.append("fast"); fast.signal() }])
            ])
        }
        expect(await wait(entered), "Slow application reached its injected native call")
        expect(await wait(fast), "Another application begins and finishes while the slow call is blocked")
        expect(!log.values.contains("slow-end"), "Fast application was not held behind the slow provider")
        release.signal()
        do { try await batch.value } catch { expect(false, "Concurrent batch failed: \(error)") }
        await executor.drain()
        print("PASS Concurrent application starts without head-of-line blocking")
    }

    private static func sameApplicationOrder() async {
        let log = Log(), executor = transport()
        do {
            try await executor.perform([
                .init(pid: 33, positions: [.init("a") { log.append("a-start"); log.append("a-end") }]),
                .init(pid: 33, positions: [.init("b") { log.append("b-start"); log.append("b-end") }])
            ])
        } catch { expect(false, "Same-PID frame failed") }
        expect(log.values == ["a-start", "a-end", "b-start", "b-end"],
               "Multiple windows in the same application retain their original order")
        await executor.drain()
        print("PASS Same-PID operations remain serialized")
    }

    private static func sessionAnimationLease() async {
        let log = Log()
        let executor = MotionBatchTransport(animationFactory: {
            MotionAppAnimations(read: { _ in log.append("read"); return .enabled(true) },
                write: { _, enabled in log.append(enabled ? "restore" : "disable"); return true })
        })
        let work = MotionBatchTransport.Work(pid: 44, positions: [.init("window") { log.append("position") }])
        do { try await executor.perform([work]); try await executor.perform([work]) }
        catch { expect(false, "Lease frame failed") }
        expect(log.values == ["read", "disable", "position", "position"],
               "Two motion frames perform one read/disable and no intervening restore")
        await executor.drain()
        expect(log.values == ["read", "disable", "position", "position", "restore"],
               "The true enhanced-UI value is restored once at the session barrier")
        await executor.drain()
        expect(log.values.filter { $0 == "restore" }.count == 1, "Repeated drain does not duplicate a successful restoration")
        print("PASS Gesture-long animation lease without per-frame toggles")
    }

    private static func errorAndRestorationDebt() async {
        let log = Log()
        // This factory is used by one injected PID, so the counter is confined
        // to its application lane just like native animation state.
        var attempts = 0
        let executor = MotionBatchTransport(animationFactory: {
            MotionAppAnimations(read: { _ in .enabled(true) }, write: { _, enabled in
                if !enabled { log.append("disable"); return true }
                attempts += 1; log.append("restore-\(attempts)"); return attempts > 1
            })
        })
        do {
            try await executor.perform([.init(pid: 55, positions: [.init("error") {
                log.append("write-error"); throw Failure.expected
            }])])
            expect(false, "A failed native write must fail its frame")
        } catch Failure.expected { expect(true, "The original native error crosses the frame barrier") }
        catch { expect(false, "Unexpected native failure") }
        expect(log.values == ["disable", "write-error", "restore-1"],
               "A lane error releases its animation lease after native work ends")
        await executor.drain()
        expect(log.values.last == "restore-2", "Failed flag restoration remains owed and is retried by drain")
        await executor.drain()
        expect(log.values.filter { $0.hasPrefix("restore") }.count == 2,
               "Successful debt retry clears the restoration obligation")
        print("PASS Native errors and restoration-debt retry")
    }

    private static func transientAnimationReadRetries() async {
        let log = Log()
        var reads = 0
        let executor = MotionBatchTransport(animationFactory: {
            MotionAppAnimations(read: { _ in
                reads += 1; log.append("read-\(reads)")
                return reads == 1 ? .retry : .enabled(true)
            }, write: { _, enabled in log.append(enabled ? "restore" : "disable"); return true })
        })
        let work = MotionBatchTransport.Work(pid: 56, positions: [.init("retry") { log.append("position") }])
        do {
            try await executor.perform([work])
            expect(log.values == ["read-1", "position"], "Transient capability read does not prevent movement or claim a lease")
            try await executor.perform([work])
            try await executor.perform([work])
        } catch { expect(false, "Transient capability fixture failed") }
        expect(log.values == ["read-1", "position", "read-2", "disable", "position", "position"],
               "The next frame retries capability, then retains exactly one acquired lease")
        await executor.drain()
        expect(log.values.last == "restore" && log.values.filter { $0 == "restore" }.count == 1,
               "The successfully retried capability restores once at session end")
        print("PASS Transient animation capability reads remain retryable")
    }

    private static func cancellationDrainsAllNativeCalls() async {
        let log = Log(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let executor = MotionBatchTransport(animationFactory: {
            MotionAppAnimations(read: { _ in .enabled(true) }, write: { _, enabled in
                log.append(enabled ? "restore" : "disable"); return true
            })
        })
        let batch = Task {
            do {
                try await executor.perform([.init(pid: 66, positions: [
                    .init("blocked") {
                        log.append("native-start"); entered.signal()
                        guard release.wait(timeout: .now() + 2) == .success else { throw Failure.timeout }
                        log.append("native-end")
                    }, .init("cancelled-next") { log.append("unwanted-next-write") }
                ])])
                log.append("unwanted-success")
            } catch is CancellationError { log.append("cancel-complete") }
            catch { log.append("unexpected-error") }
        }
        expect(await wait(entered), "Cancellation fixture entered native work")
        batch.cancel()
        let drain = Task { await executor.drain(); log.append("drain-complete") }
        expect(!log.values.contains("restore") && !log.values.contains("cancel-complete"),
               "Cancellation cannot restore flags or complete before the outstanding call returns")
        release.signal(); await batch.value; await drain.value
        let events = log.values
        expect(!events.contains("unwanted-next-write") && !events.contains("unwanted-success"),
               "Cancellation suppresses later writes in the same application")
        expect(events.firstIndex(of: "native-end")! < events.firstIndex(of: "restore")!,
               "Animation restoration follows the last outstanding native call")
        expect(events.firstIndex(of: "native-end")! < events.firstIndex(of: "drain-complete")!,
               "Recovery/resize drain cannot overtake motion")
        print("PASS Cancellation waits for all outstanding native work")
    }

    private static func localMainAndRaiseOrder() async {
        let log = Log(), executor = transport(log: Log())
        do {
            try await executor.perform([
                .init(pid: 77, positions: [.init("external") { log.append("external-position") }],
                      raises: [.init("external") { log.append("external-raise") }])
            ], local: .init(positions: [.init("local") {
                log.append(Thread.isMainThread ? "local-main-position" : "wrong-thread")
            }], raises: [.init("local") { log.append("local-raise") }]))
        } catch { expect(false, "Local/external batch failed") }
        let events = log.values
        expect(events.contains("local-main-position") && !events.contains("wrong-thread"),
               "AppKit positions run on main and join the shared completion barrier")
        expect(events.firstIndex(of: "external-position")! < events.firstIndex(of: "external-raise")!,
               "Prevalidated boundary raising follows positions in its app lane")
        expect(events.firstIndex(of: "local-main-position")! < events.firstIndex(of: "local-raise")!,
               "Local boundary raising follows its local position")
        await executor.drain()
        print("PASS Main-thread local work and merged raise order")
    }

    private static func obsoleteQueuedFrames() async {
        let log = Log(), executor = transport(log: log)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let current = Task {
            try await executor.perform([.init(pid: 88, positions: [.init("current") {
                entered.signal()
                guard release.wait(timeout: .now() + 2) == .success else { throw Failure.timeout }
            }])])
        }
        expect(await wait(entered), "Latest-frame fixture holds one current barrier")
        let stale = Task {
            do { try await executor.perform([.init(pid: 88, positions: [.init("stale") { log.append("stale") }])]) }
            catch is CancellationError { log.append("stale-skipped") }
            catch { log.append("unexpected-error") }
        }
        expect(await until { log.rows("motion-batch-queued").count >= 2 }, "A supersedable frame was queued")
        let latest = Task {
            try await executor.perform([.init(pid: 88, positions: [.init("latest") { log.append("latest") }])])
        }
        expect(await until { log.rows("motion-batch-queued").count >= 3 }, "The latest frame replaced stale intent")
        release.signal()
        do { try await current.value; await stale.value; try await latest.value }
        catch { expect(false, "Latest frame failed") }
        expect(!log.values.contains("stale") && log.values.contains("stale-skipped") && log.values.contains("latest"),
               "Superseded queued frames never produce native writes")
        let metrics = log.rows("motion-batch")
        expect(metrics.count == 2 && metrics.allSatisfy {
            ($0["startSkewMS"] as? Double)?.isFinite == true &&
            ($0["finishSkewMS"] as? Double)?.isFinite == true &&
            ($0["writeSpanMS"] as? Double)?.isFinite == true
        }, "Completed frames report finite per-app start/finish skew and write spans")
        expect(log.rows("motion-operation-begin").count == log.rows("motion-operation-end").count,
               "Each actual native operation has matching begin/end telemetry")
        await executor.drain()
        print("PASS Latest queued frame and comparable transport telemetry")
    }
}
