import AppKit
import ApplicationServices
import Darwin
import RibbonCore
import SpaceInterop

/// macOS has no public API for transferring another app's window between Spaces.
/// Keep the optional SkyLight entry points here, resolve them at runtime, and
/// verify membership after every transfer (a successful return can be a no-op).
/// Signatures/14.5+ compatibility sequence: Hammerspoon extensions/spaces/private.h
/// and libspaces.m. No injection, privileged helper, or SIP changes are used.
@MainActor
final class SpaceService {
    typealias MainConnection = @convention(c) () -> Int32
    typealias CopyDisplays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias SetCompat = @convention(c) (Int32, UInt64, Int32) -> Int32
    typealias SetWorkspace = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, Int32) -> Int32
    typealias MoveWindows = @convention(c) (Int32, CFArray, UInt64) -> Void
    typealias WindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
    typealias CopyWindows = @convention(c) (Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?

    struct Desktop: Equatable {
        let displayUUID: String
        let current: UInt64
        let userSpaces: Set<UInt64>
    }

    private let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private let ax = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)
    private func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer?) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
    private var connection: Int32? {
        let function: MainConnection? = symbol("SLSMainConnectionID", in: sky)
        return function?()
    }
    func windowNumber(_ element: AXUIElement) -> UInt32? {
        let function: WindowNumber? = symbol("_AXUIElementGetWindow", in: ax)
        var number: UInt32 = 0
        guard function?(element, &number) == 0, number != 0 else { return nil }
        return number
    }
    func desktops() throws -> [Desktop] {
        let copy: CopyDisplays? = symbol("SLSCopyManagedDisplaySpaces", in: sky)
        guard let connection, let raw = copy?(connection)?.takeRetainedValue() as? [[String: Any]] else {
            throw WindowControlError.message("This macOS version cannot enumerate desktop Spaces. No windows moved.")
        }
        let result = raw.compactMap { item -> Desktop? in
            guard let uuid = item["Display Identifier"] as? String,
                  let current = item["Current Space"] as? [String: Any],
                  let currentID = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value,
                  let entries = item["Spaces"] as? [[String: Any]] else { return nil }
            let ids = entries.compactMap { entry -> UInt64? in
                guard (entry["type"] as? NSNumber)?.intValue == 0 else { return nil }
                return (entry["ManagedSpaceID"] as? NSNumber)?.uint64Value
            }
            return Desktop(displayUUID: uuid, current: currentID, userSpaces: Set(ids))
        }
        guard !result.isEmpty else { throw WindowControlError.message("Desktop Space information is unavailable. No windows moved.") }
        return result
    }
    func spaces(for number: UInt32) -> [UInt64]? {
        let copy: CopySpaces? = symbol("SLSCopySpacesForWindows", in: sky)
        guard let connection, let raw = copy?(connection, 0x7, [NSNumber(value: number)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return raw.map(\.uint64Value).sorted()
    }
    func nonMinimizedWindows(in desktops: [Desktop]) throws -> Set<UInt32> {
        let copy: CopyWindows? = symbol("SLSCopyWindowsWithOptionsAndTags", in: sky)
        let ids = Set(desktops.flatMap(\.userSpaces)).map { NSNumber(value: $0) }
        var setTags: UInt64 = 0, clearTags: UInt64 = 0
        guard let connection,
              let raw = copy?(connection, 0, ids as CFArray, 0x2, &setTags, &clearTags)?.takeRetainedValue() as? [NSNumber] else {
            throw WindowControlError.message("Could not distinguish minimized windows across desktops. No windows moved.")
        }
        return Set(raw.map(\.uint32Value))
    }
    static func destination(for display: DisplayInfo, in desktops: [Desktop]) -> UInt64? {
        let uuid: String? = UInt32(display.id).flatMap { number in
            guard let value = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
            return CFUUIDCreateString(nil, value) as String
        }
        let desktop = desktops.first { $0.displayUUID == uuid } ?? (desktops.count == 1 ? desktops.first : nil)
        guard let desktop, desktop.userSpaces.contains(desktop.current) else { return nil }
        return desktop.current
    }
    func move(_ number: UInt32, to target: UInt64) async throws {
        try Task.checkCancellation()
        guard let before = spaces(for: number) else { throw WindowControlError.message("Could not read a window's desktop membership.") }
        if before.contains(target) { return }
        guard before.count == 1, try desktops().contains(where: { $0.userSpaces.contains(target) }) else {
            throw WindowControlError.message("The original or destination desktop is unavailable. Its recovery entry was kept.")
        }
        guard let connection else { throw WindowControlError.message("Space transfers are unavailable.") }
        if RDHasBridgedSpaceMove() {
            guard RDSubmitSpaceMove(number, target) else { throw WindowControlError.message("Could not submit a desktop transfer.") }
        } else if #available(macOS 14.5, *) {
            let compat: SetCompat? = symbol("SLSSpaceSetCompatID", in: sky)
            let workspace: SetWorkspace? = symbol("SLSSetWindowListWorkspace", in: sky)
            guard let compat, let workspace else { throw WindowControlError.message("This macOS version does not support Space transfers.") }
            // Temporary routing identifier only; always remove it, including on error.
            // The 14.5+ WindowServer compatibility route uses this specific
            // workspace marker (also used by Hammerspoon/yabai).
            let routingID: Int32 = 0x79616265
            _ = compat(connection, target, routingID)
            defer { _ = compat(connection, target, 0) }
            var windowID = number
            _ = workspace(connection, &windowID, 1, routingID)
        } else {
            let move: MoveWindows? = symbol("SLSMoveWindowsToManagedSpace", in: sky)
            guard let move else { throw WindowControlError.message("This macOS version does not support Space transfers.") }
            move(connection, [NSNumber(value: number)] as CFArray, target)
        }
        for _ in 0..<50 {
            try Task.checkCancellation()
            if spaces(for: number) == [target] { return }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        throw WindowControlError.message("macOS did not move the window to the requested desktop. Control stopped; originals remain saved.")
    }
}
