import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent("ribbon-app-behavior-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
let store = AppBehaviorStore(directory: root)
var data = try store.read()
assert(!data.promptForNewWindows && data.apps.isEmpty && data.history.isEmpty)
assert(data.behavior(for: "unknown") == .inherit)
for behavior in AppWindowBehavior.allCases {
    assert(behavior.shouldPrompt(global: false) == (behavior == .ask))
    assert(behavior.shouldPrompt(global: true) == (behavior == .ask || behavior == .inherit))
}
data.discover(bundleID: "com.example.editor", name: "Editor")
data.discover(bundleID: "com.example.editor", name: "New Editor")
data.discover(bundleID: "", name: "Unknown")
data.discover(bundleID: "local.paneru.preferences", name: "RibbonDesk")
assert(data.apps.count == 1 && data.apps[0].name == "New Editor")
data.apps[0].behavior = .ribbon
data.promptForNewWindows = true
var reloads = 0
try store.write(data) { reloads += 1 }
let restored = try store.read()
assert(restored == data && reloads == 1)
for file in [store.json, store.lua] {
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    assert((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}
for index in 0..<250 { data.record(bundleID: "com.example.editor", name: "Editor", action: "Decision \(index)") }
assert(
    data.history.count == 200 && data.history.first?.action == "Decision 249"
        && data.history.last?.action == "Decision 50")
try store.write(data) { reloads += 1 }
assert(reloads == 1, "history changes must not reload the engine")
let previousJSON = try Data(contentsOf: store.json)
let previousLua = try Data(contentsOf: store.lua)
enum FixtureError: Error { case reload }
data.apps[0].behavior = .floating
do {
    try store.write(data) { throw FixtureError.reload }
    assertionFailure("reload should fail")
} catch FixtureError.reload {}
let afterJSON = try Data(contentsOf: store.json)
let afterLua = try Data(contentsOf: store.lua)
assert(afterJSON == previousJSON && afterLua == previousLua, "failed saves must restore catalog and engine rules")
data.apps[0].bundleID = "com.example.\"; error('injected') --\n漢字"
data.apps[0].behavior = .ask
assert(!data.luaSource.contains("error('injected')") && !data.luaSource.contains("漢字"))
assert(data.luaSource.contains("\\034") && data.luaSource.contains("\\010"))
try store.write(data)
let escaped = try store.read()
assert(escaped == data)
let output =
    CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1]) : root.appendingPathComponent("escaped.lua")
try Data(data.luaSource.utf8).write(to: output)

let buffer = AppBehaviorEventBuffer()
let event =
    #"{"event":"window_opened","window_id":42,"pid":123,"app_name":"Editor","bundle_id":"com.example.editor","floating":true,"startup":false}"#
let bytes = Data((event + "\n").utf8)
assert(buffer.consume(bytes.prefix(23)).isEmpty)
let parsed = buffer.consume(bytes.dropFirst(23))
assert(parsed.count == 1 && parsed[0].window_id == 42 && parsed[0].startup == false)
let closed = buffer.consume(Data("{\"event\":\"window_unavailable\",\"window_id\":42}\n".utf8))
assert(closed.count == 1 && closed[0].event == "window_unavailable" && closed[0].window_id == 42)
assert(
    buffer.consume(Data(("malformed\n{\"event\":\"window_focused\"}\n" + event + "\n" + event + "\n").utf8)).count == 2)
assert(buffer.consume(Data(repeating: 65, count: 4 * 1024 * 1024 + 1)).isEmpty)
assert(buffer.consume(bytes).count == 1, "oversize recovery must reset framing")

try FileManager.default.removeItem(at: store.lua)
let target = root.appendingPathComponent("preserve.txt")
try Data("preserve".utf8).write(to: target)
try FileManager.default.createSymbolicLink(at: store.lua, withDestinationURL: target)
do {
    try store.write(data)
    assertionFailure("symlink accepted")
} catch {}
let targetText = try String(contentsOf: target, encoding: .utf8)
assert(targetText == "preserve")
try FileManager.default.removeItem(at: store.lua)
try Data("invalid JSON".utf8).write(to: store.json)
do {
    _ = try store.read()
    assertionFailure("corrupt catalog accepted")
} catch {}
print(
    "App Behavior: defaults, prompt policy, app identity, persistence, bounded log, export escaping, rollback, private files and stream framing passed."
)
