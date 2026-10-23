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
assert(legacy.momentum == 1.0 && legacy.momentumDecay == 4.0 && legacy.snapSpeed == 0.8 && legacy.snapVisible == 0.55)
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

let scrolling = Preferences(speed: 0.35, gap: 4, momentum: 1.7, snapSpeed: 1.2, snapVisible: 0.75).validated
let scrollData = try JSONEncoder().encode(scrolling)
let restoredScrolling = try JSONDecoder().decode(Preferences.self, from: scrollData)
assert(restoredScrolling == scrolling)
let scrollLua = scrolling.luaSource(disabledSpaceIDs: [])
assert(scrollLua.contains("momentum = 1.70") && scrollLua.contains("snap_speed = 1.20") && scrollLua.contains("snap_visible = 0.75"))
let boundedScroll = Preferences(speed: 0.35, gap: 4, momentum: -.infinity, snapSpeed: 99, snapVisible: -.nan).validated
assert(boundedScroll.momentum == 1 && boundedScroll.snapSpeed == 3 && boundedScroll.snapVisible == 0.55)
let noScroll = Preferences(speed: 0.35, gap: 4, momentum: 0, snapSpeed: 0, snapVisible: 0).validated
assert(noScroll.momentum == 0 && noScroll.snapSpeed == 0 && noScroll.snapVisible == 0.25)
print("Scroll preferences: migration, persistence, Lua output, defaults, off values, and invalid values passed.")

assert(BorderColor.parsedHex("#12") == nil && BorderColor.parsedHex("invalid") == nil)
assert(BorderColor.parsedHex(" #aBc123 ") == "#ABC123")
print("Live color input: incomplete colors wait; complete colors normalize correctly.")

let beforeDecay = try JSONDecoder().decode(Preferences.self, from: Data("""
{"speed":0.55,"gap":4,"momentum":2.2,"snapSpeed":1.3,"snapVisible":0.85}
""".utf8))
assert(beforeDecay.momentum == 2.2 && beforeDecay.momentumDecay == 4.0)
assert(beforeDecay.speed == 0.55 && beforeDecay.snapSpeed == 1.3 && beforeDecay.snapVisible == 0.85)
let shortCoast = Preferences(speed: 0.55, gap: 4, momentum: 2.2, momentumDecay: 8.5).validated
let decayData = try JSONEncoder().encode(shortCoast)
let restoredDecay = try JSONDecoder().decode(Preferences.self, from: decayData)
assert(restoredDecay == shortCoast)
assert(shortCoast.luaSource(disabledSpaceIDs: []).contains("momentum_decay = 8.50"))
assert(Preferences(speed: 0.55, gap: 4, momentumDecay: .nan).validated.momentumDecay == 4.0)
assert(Preferences(speed: 0.55, gap: 4, momentumDecay: 999).validated.momentumDecay == 100.0)
assert(Preferences(speed: 0.55, gap: 4, momentumDecay: 0).validated.momentumDecay == 1.0)
print("Momentum decay: migration preserves tuning; persistence, Lua output, bounds, and invalid values passed.")

assert(legacy.snapAnimation == 1 && legacy.snapFullWidth && legacy.snapHalfWidth)
assert(!legacy.snapBack && legacy.snapExitDistance == 0.12)
var tuned = shortCoast
// These deliberately differ from every default so omissions in persistence fail.
tuned.threeFingerPaging = false
tuned.snapAnimation = 2.5
tuned.snapFullWidth = false
tuned.snapHalfWidth = false
tuned.snapBack = true
tuned.snapExitDistance = 0.3
tuned.momentumDecay = 70
let tunedRoundTrip = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(tuned))
assert(tunedRoundTrip == tuned)
let tunedLua = tuned.luaSource(disabledSpaceIDs: [])
for text in ["snap_animation = 2.50", "snap_full_width = false", "snap_half_width = false", "snap_back = true", "snap_exit_distance = 0.30", "momentum_decay = 70.00"] { assert(tunedLua.contains(text)) }
var invalidTuning = tuned
invalidTuning.snapAnimation = .infinity
invalidTuning.snapExitDistance = .nan
assert(invalidTuning.validated.snapAnimation == 1 && invalidTuning.validated.snapExitDistance == 0.12)
invalidTuning.snapAnimation = 99
invalidTuning.snapExitDistance = -1
assert(invalidTuning.validated.snapAnimation == 4 && invalidTuning.validated.snapExitDistance == 0)

let presetRoot = FileManager.default.temporaryDirectory.appendingPathComponent("paneru-preset-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: presetRoot) }
let presetStore = ScrollPresetStore(url: presetRoot.appendingPathComponent("scroll-presets.json"))
let initiallyEmpty = try presetStore.read()
assert(initiallyEmpty.isEmpty)
let firstPreset = try presetStore.save(name: "  Quick  ", tuning: tuned.scrollTuning)
assert(firstPreset.name == "Quick")
let secondPreset = try presetStore.save(name: "Long coast", tuning: Preferences.defaults.scrollTuning)
let reloadedPresets = try presetStore.read()
assert(reloadedPresets.count == 2 && reloadedPresets.contains(firstPreset))
let replacement = try presetStore.save(name: "QUICK", tuning: scrolling.scrollTuning)
assert(replacement.id == firstPreset.id && replacement.tuning == scrolling.scrollTuning)
let afterReplace = try presetStore.read()
assert(afterReplace.count == 2)
var unrelated = custom
unrelated.scrollTuning = tuned.scrollTuning
assert(unrelated.gap == custom.gap && unrelated.borderColor == custom.borderColor)
assert(unrelated.disabledSpaceUUIDs == custom.disabledSpaceUUIDs && unrelated.launchAtLogin == custom.launchAtLogin && unrelated.focusMode == custom.focusMode)
assert(unrelated.scrollTuning == tuned.scrollTuning)
try presetStore.delete(id: secondPreset.id)
let afterDelete = try presetStore.read()
assert(afterDelete == [replacement])
let presetPermissions = try FileManager.default.attributesOfItem(atPath: presetStore.url.path)
assert((presetPermissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
do { try presetStore.save(name: "  ", tuning: tuned.scrollTuning); assertionFailure("empty name accepted") } catch { }
try Data("corrupt".utf8).write(to: presetStore.url)
do { try presetStore.save(name: "Preserve", tuning: tuned.scrollTuning); assertionFailure("corrupt presets overwritten") } catch { }
let preservedPresets = try String(contentsOf: presetStore.url, encoding: .utf8)
assert(preservedPresets == "corrupt")
print("Snap tuning + feel presets: migration, roundtrip, bounds, Lua output, save/update/load/delete, policy preservation and corrupt-file protection passed.")

assert(legacy.threeFingerPaging && Preferences.defaults.threeFingerPaging)
assert(tuned.luaSource(disabledSpaceIDs: []).contains("three_finger_paging = false"))
var oldPresetObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tuned.scrollTuning)) as! [String: Any]
oldPresetObject.removeValue(forKey: "threeFingerPaging")
let oldPresetTuning = try JSONDecoder().decode(ScrollTuning.self, from: JSONSerialization.data(withJSONObject: oldPresetObject))
assert(!oldPresetTuning.threeFingerPaging && oldPresetTuning == tuned.scrollTuning)
var pagingPreferences = tuned
pagingPreferences.threeFingerPaging = true
let pagingRoundTrip = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(pagingPreferences))
assert(pagingRoundTrip == pagingPreferences && pagingRoundTrip.validated.threeFingerPaging)
assert(pagingPreferences.luaSource(disabledSpaceIDs: []).contains("three_finger_paging = true"))
assert(pagingPreferences.scrollTuning != tuned.scrollTuning)
print("Three-finger paging: live-config export, preference migration, preset migration and mode roundtrip passed.")

assert(!legacy.overviewAnimation && !Preferences.defaults.overviewAnimation)
var animatedOverview = custom
animatedOverview.overviewAnimation = true
let animatedRoundTrip = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(animatedOverview))
assert(animatedRoundTrip.overviewAnimation && animatedRoundTrip.validated.overviewAnimation)
assert(animatedOverview.scrollTuning == custom.scrollTuning, "The overview toggle must not reload scrolling or change feel presets")
var presetApplication = animatedOverview
presetApplication.scrollTuning = tuned.scrollTuning
assert(presetApplication.overviewAnimation)
print("Overview animation preference: instant migration/default, persistence, validation and preset independence passed.")
