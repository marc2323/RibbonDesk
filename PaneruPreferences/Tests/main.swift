// Compile with Sources/DesktopSpaceSession.swift; no desktop actions are taken.
var session = DesktopSpaceSession()
assert(session.shouldRun(running: false, excluded: false))
assert(!session.shouldRun(running: true, excluded: true))
assert(session.shouldRun(running: false, excluded: false), "returning to an enabled desktop resumes")
assert(!session.shouldRun(running: false, excluded: false), "a manual hotkey pause remains paused")
assert(!session.shouldRun(running: false, excluded: true))
assert(!session.shouldRun(running: false, excluded: false))
session.request(true)
assert(!session.shouldRun(running: false, excluded: true))
assert(session.shouldRun(running: false, excluded: false))
session.policyChanged()
assert(!session.shouldRun(running: false, excluded: true))
session.request(false)
assert(!session.shouldRun(running: false, excluded: true))
assert(!session.shouldRun(running: false, excluded: false))
var startup = DesktopSpaceSession()
assert(!startup.shouldRun(running: false, excluded: true), "excluded desktop never starts the engine")
assert(startup.shouldRun(running: false, excluded: false))
startup.policyChanged()
assert(!startup.shouldRun(running: false, excluded: true), "saving an exclusion preserves the run request")
startup.policyChanged()
assert(startup.shouldRun(running: false, excluded: false))
print("Desktop policy: 15 assertions passed.")

// Compile with Sources/Preferences.swift as well.
import Foundation
let legacy = try JSONDecoder().decode(Preferences.self, from: Data("""
{"speed":0.5,"gap":4,"focusMode":"click","launchAtLogin":true,"disabledSpaceUUIDs":["desktop-a"]}
""".utf8))
assert(legacy.speed == 0.5 && legacy.gap == 4 && legacy.focusMode == .click)
assert(legacy.launchAtLogin && legacy.disabledSpaceUUIDs == ["desktop-a"])
assert(legacy.borderEnabled && legacy.borderColor == BorderColor.defaultHex)
let custom = Preferences(speed: 0.5, gap: 4, focusMode: .click, launchAtLogin: true,
                         disabledSpaceUUIDs: ["desktop-a"], borderEnabled: false, borderColor: " #ff8800 ").validated
assert(custom.borderColor == "#FF8800" && !custom.borderEnabled)
let encoded = try JSONEncoder().encode(custom)
let decoded = try JSONDecoder().decode(Preferences.self, from: encoded)
assert(decoded == custom)
let source = custom.luaSource(disabledSpaceIDs: [42, 81])
assert(source.contains("border_enabled = false") && source.contains("border_color = \"#FF8800\""))
assert(source.contains("speed = 0.50") && source.contains("gap = 4") && source.contains("focus_follows_mouse = false"))
assert(source.contains("disabled_spaces = { 42, 81 }"))
for invalid in ["", "#fff", "#12345678", "##123456", "#éabcde", "\"; os.execute('bad') --"] {
    assert(BorderColor.normalized(invalid) == BorderColor.defaultHex)
}
assert(BorderColor.normalized("abcdef") == "#ABCDEF")
let rgb = BorderColor.components("#FF8800")
assert(BorderColor.hex(red: rgb.red, green: rgb.green, blue: rgb.blue) == "#FF8800")
assert(BorderColor.hex(red: -.infinity, green: 3, blue: -.nan) == "#00FF00")
assert(Preferences.defaults.borderEnabled && Preferences.defaults.borderColor == "#33879E")
print("Outline preferences: migration, persistence, Lua output, defaults, and invalid colors passed.")

// Compile with Sources/PrivateLogs.swift as well. These checks touch only a
// fresh temporary directory, never the user's installed LaunchAgent or logs.
import Darwin
let logTestRoot = FileManager.default.temporaryDirectory.appendingPathComponent("paneru-log-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: logTestRoot) }
let logs = logTestRoot.appendingPathComponent("Paneru")
try PrivateLogs.prepare(in: logs)
let logFile = logs.appendingPathComponent("stdout.log")
try Data("preserve existing output".utf8).write(to: logFile)
try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: logFile.path)
try PrivateLogs.prepare(in: logs)
let preservedLog = try String(contentsOf: logFile, encoding: .utf8)
assert(preservedLog == "preserve existing output")
for (url, mode) in [(logs, 0o700), (logFile, 0o600)] {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    assert((attributes[.posixPermissions] as? NSNumber)?.intValue == mode)
}
func assertUnsafeLogRejected(_ directory: URL) {
    do { try PrivateLogs.prepare(in: directory); assertionFailure("unsafe log accepted") }
    catch { }
}
try FileManager.default.removeItem(at: logFile)
let target = logTestRoot.appendingPathComponent("must-not-create")
try FileManager.default.createSymbolicLink(at: logFile, withDestinationURL: target)
assertUnsafeLogRejected(logs)
assert(!FileManager.default.fileExists(atPath: target.path))
try FileManager.default.removeItem(at: logFile)
let hardLinkTarget = logTestRoot.appendingPathComponent("hard-link-target")
try Data("unchanged".utf8).write(to: hardLinkTarget)
try FileManager.default.linkItem(at: hardLinkTarget, to: logFile)
assertUnsafeLogRejected(logs)
try FileManager.default.removeItem(at: logFile)
assert(mkfifo(logFile.path, 0o600) == 0)
assertUnsafeLogRejected(logs)
try FileManager.default.removeItem(at: logs)
try FileManager.default.createSymbolicLink(at: logs, withDestinationURL: logTestRoot)
assertUnsafeLogRejected(logs)
print("Private logs: permissions, preservation, symlink, hard-link, FIFO and directory-link rejection passed.")
