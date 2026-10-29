import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppBehaviorModel: ObservableObject {
    @Published private(set) var data = AppBehaviorData()
    @Published var search = ""
    @Published var message = "New windows float. Control–Option–T adds the focused window to the Ribbon."
    @Published private(set) var failed = false
    private let store: AppBehaviorStore
    private var readable = true
    private let reloadConfig: () throws -> Void
    var canEdit: Bool { readable }

    init(
        store: AppBehaviorStore = AppBehaviorStore(directory: PreferenceFiles.directory),
        reloadConfig: @escaping () throws -> Void = {
            if FileManager.default.fileExists(atPath: PreferenceFiles.script.path) { try PreferenceFiles.reload() }
        }
    ) {
        self.store = store
        self.reloadConfig = reloadConfig
        do {
            data = try store.read()
            try store.write(data, reload: reloadConfig)
        } catch {
            readable = false
            failed = true
            message = "Couldn’t read App Behavior. " + error.localizedDescription
        }
    }

    var apps: [AppBehaviorRule] {
        data.apps.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.bundleID.localizedCaseInsensitiveContains(search)
        }
    }

    private func save(_ next: AppBehaviorData, message success: String? = nil) {
        guard readable else { return }
        do {
            try store.write(next, reload: reloadConfig)
            data = next
            failed = false
            if let success { message = success }
        } catch {
            failed = true
            message = "Couldn’t save App Behavior. " + error.localizedDescription
        }
    }

    func discover(bundleID: String, name: String) {
        discover([(bundleID, name)])
    }

    func discover(_ apps: [(String, String)]) {
        var next = data
        for (bundleID, name) in apps { next.discover(bundleID: bundleID, name: name) }
        if next != data { save(next) }
    }

    func setBehavior(_ behavior: AppWindowBehavior, bundleID: String, name: String) {
        var next = data
        next.discover(bundleID: bundleID, name: name)
        guard let index = next.apps.firstIndex(where: { $0.bundleID == bundleID }),
            next.apps[index].behavior != behavior
        else { return }
        next.apps[index].behavior = behavior
        next.record(bundleID: bundleID, name: name, action: "Preference: \(behavior.label)")
        save(next, message: "Saved for \(name). Applies to future windows.")
    }

    func setWidth(_ width: AppWindowWidth, bundleID: String, name: String) {
        var next = data
        next.discover(bundleID: bundleID, name: name)
        guard let index = next.apps.firstIndex(where: { $0.bundleID == bundleID }),
            next.apps[index].width != width
        else { return }
        next.apps[index].width = width
        next.record(bundleID: bundleID, name: name, action: "Width: \(width.label)")
        save(next, message: "Saved for \(name). Applies when its windows join the Ribbon.")
    }

    func setPrompts(_ enabled: Bool) {
        var next = data
        next.promptForNewWindows = enabled
        next.record(
            bundleID: "", name: "Global default",
            action: enabled ? "Prompts enabled" : "Prompts disabled; use Control–Option–T")
        save(next)
    }

    func record(_ event: AppBehaviorEvent, action: String) {
        var next = data
        next.discover(bundleID: event.bundle_id, name: event.app_name)
        next.record(bundleID: event.bundle_id, name: event.app_name, action: action)
        save(next)
    }

    func clearHistory() {
        var next = data
        next.history = []
        save(next, message: "Log cleared. App preferences are saved.")
    }

    func resetPreferences() {
        var next = data
        for index in next.apps.indices {
            next.apps[index].behavior = .inherit
            next.apps[index].width = .automatic
        }
        next.promptForNewWindows = false
        next.record(bundleID: "", name: "All apps", action: "Reset preferences: float by default; prompts off")
        save(next, message: "App preferences reset. Future windows float until Control–Option–T.")
    }

    func addApp() {
        let picker = NSOpenPanel()
        picker.title = "Add an app to App Behavior"
        picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        var next = data
        for url in picker.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name =
                bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            next.discover(bundleID: id, name: name)
        }
        if next != data { save(next) }
    }
}

struct AppBehaviorView: View {
    @ObservedObject var model: AppBehaviorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App Behavior").font(.title2.bold())
            Text(
                "New windows float at their normal size. Press Control–Option–T to add the focused window to the Ribbon; press it again to float it."
            )
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(
                "Ask about each new window using the global default",
                isOn: Binding(
                    get: { model.data.promptForNewWindows }, set: { model.setPrompts($0) }))
            Text("Prompts start off. App choices below override this setting. Saved sessions retain their arrangement.")
                .font(.caption).foregroundStyle(.secondary)
            appSearch
            appList
            logHeader
            logList
            footer
        }.padding(20).frame(minWidth: 820, minHeight: 620)
            .background(Color(nsColor: .windowBackgroundColor))
            .disabled(!model.canEdit)
    }

    private var appSearch: some View {
        HStack {
            TextField("Search apps or bundle identifiers", text: $model.search).textFieldStyle(.roundedBorder)
            Button("Add App…", action: model.addApp)
        }
    }

    private var appList: some View {
        List(model.apps) { app in
            appRow(app)
        }.overlay {
            if model.apps.isEmpty {
                Text(
                    model.search.isEmpty
                        ? "Apps appear as their windows open. You can also add an app above." : "No matching apps."
                )
                .foregroundStyle(.secondary).padding()
            }
        }
    }

    private func appRow(_ app: AppBehaviorRule) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name.isEmpty ? app.bundleID : app.name).fontWeight(.medium)
                Text(app.bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Picker(
                "Behavior for \(app.name)",
                selection: Binding(
                    get: { model.data.behavior(for: app.bundleID) },
                    set: { model.setBehavior($0, bundleID: app.bundleID, name: app.name) })
            ) {
                ForEach(AppWindowBehavior.allCases) { Text($0.label).tag($0) }
            }.labelsHidden().frame(width: 235)
            Picker(
                "Width for \(app.name)",
                selection: Binding(
                    get: { model.data.width(for: app.bundleID) },
                    set: { model.setWidth($0, bundleID: app.bundleID, name: app.name) })
            ) {
                ForEach(AppWindowWidth.allCases) { Text($0.label).tag($0) }
            }.labelsHidden().frame(width: 150)
                .help("Column width when this app's windows join the Ribbon.")
        }.padding(.vertical, 3)
    }

    private var logHeader: some View {
        HStack {
            Text("Recent activity · last \(AppBehaviorData.historyLimit) entries").font(.headline)
            Spacer()
            Button("Clear Log", action: model.clearHistory).disabled(model.data.history.isEmpty)
        }
    }

    private var logList: some View {
        List(
            model.data.history.filter {
                model.search.isEmpty || $0.appName.localizedCaseInsensitiveContains(model.search)
                    || $0.bundleID.localizedCaseInsensitiveContains(model.search)
            }
        ) { entry in
            HStack(alignment: .top) {
                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption)
                    .foregroundStyle(.secondary).frame(width: 115, alignment: .leading)
                Text(entry.appName).frame(width: 135, alignment: .leading).lineLimit(1).help(entry.bundleID)
                Text(entry.action).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 12)).padding(.vertical, 2)
        }.frame(height: 155)
    }

    private var footer: some View {
        HStack {
            Text(model.message).font(.caption).foregroundStyle(model.failed ? .red : .secondary)
                .textSelection(.enabled)
            Spacer()
            Button("Reset App Preferences", action: model.resetPreferences)
        }
    }
}

private final class AppBehaviorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct AppBehaviorPrompt: View {
    let event: AppBehaviorEvent
    let choose: (Bool, Bool) -> Void
    @State private var remember = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add \(event.app_name) to the Ribbon?").font(.headline)
            Text("This new window is floating. You can also use Control–Option–T while it is focused.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Remember for this app", isOn: $remember)
            HStack {
                Button("Keep Floating") { choose(false, remember) }
                Spacer()
                Button("Add to Ribbon") { choose(true, remember) }
            }
        }.padding(18).frame(width: 360)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
final class AppBehaviorController: NSObject, NSWindowDelegate {
    let model = AppBehaviorModel()
    var canPrompt: () -> Bool = { true }
    private var window: NSWindow?
    private var prompt: AppBehaviorPanel?
    private var current: AppBehaviorEvent?
    private var queue: [AppBehaviorEvent] = []
    private var subscription: Process?
    private var pipe: Pipe?
    private var retry: Task<Void, Never>?
    private var generation = UUID()
    private var running = false
    private var retryDelay: UInt64 = 1
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.dismissPrompts() }
            })
    }

    func showSettings() {
        dismissPrompts()
        if window == nil {
            let controller = NSHostingController(rootView: AppBehaviorView(model: model))
            let value = NSWindow(contentViewController: controller)
            value.title = "RibbonDesk — App Behavior"
            value.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            value.setContentSize(NSSize(width: 760, height: 680))
            value.minSize = NSSize(width: 740, height: 660)
            value.isReleasedWhenClosed = false
            value.center()
            window = value
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func sync(running: Bool) {
        self.running = running
        if running {
            if subscription == nil && retry == nil { subscribe() }
        } else {
            stopSubscription()
            dismissPrompts()
        }
    }

    func stop() {
        running = false
        stopSubscription()
        dismissPrompts()
        window?.close()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }

    private func stopSubscription() {
        generation = UUID()
        retry?.cancel()
        retry = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let subscription, subscription.isRunning { subscription.terminate() }
        subscription = nil
        try? pipe?.fileHandleForReading.close()
        pipe = nil
    }

    private func subscribe() {
        let process = Process()
        let output = Pipe()
        let buffer = AppBehaviorEventBuffer()
        let token = UUID()
        generation = token
        process.executableURL = URL(fileURLWithPath: Engine.binary)
        process.arguments = ["subscribe", "--json", "--window-behavior"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let events = buffer.consume(handle.availableData)
            guard !events.isEmpty else { return }
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.retryDelay = 1
                for event in events { self.receive(event) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.reconnect()
            }
        }
        do {
            try process.run()
            subscription = process
            pipe = output
            // Populate the editor from already-open windows without prompting
            // or treating a reconnect/session restore as new window creation.
            Task {
                let snapshot = try? await Task.detached {
                    let text = try Engine.run(["query", "state", "--json"])
                    return try JSONDecoder().decode(RibbonSnapshot.self, from: Data(text.utf8))
                }.value
                guard generation == token, let snapshot else { return }
                model.discover(snapshot.virtual_workspaces.flatMap(\.windows).map { ($0.bundle_id, $0.app_name) })
            }
        } catch { reconnect() }
    }

    private func reconnect() {
        stopSubscription()
        dismissPrompts()
        guard running else { return }
        let delay = retryDelay
        retryDelay = min(15, retryDelay * 2)
        retry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            guard let self, self.running else { return }
            // Looking up a launchd Mach service can wake its job. A keyboard
            // pause must stay paused even before the desktop model refreshes.
            let engineRunning = await Task.detached { Engine.isRunning() }.value
            guard !Task.isCancelled, self.running else { return }
            self.retry = nil
            if engineRunning { self.subscribe() } else { self.running = false }
        }
    }

    private func receive(_ event: AppBehaviorEvent) {
        if event.event == "window_unavailable" {
            queue.removeAll { $0.window_id == event.window_id }
            if current?.window_id == event.window_id {
                closePrompt()
                presentNext()
            }
            return
        }
        guard !event.bundle_id.isEmpty, event.bundle_id != "local.paneru.preferences" else { return }
        if event.event == "window_behavior_changed" {
            model.record(event, action: event.floating ? "Window floated" : "Window added to Ribbon")
            queue.removeAll { $0.key == event.key }
            if current?.key == event.key {
                closePrompt()
                presentNext()
            }
        } else if event.startup == true {
            model.discover(bundleID: event.bundle_id, name: event.app_name)
        } else {
            model.record(event, action: event.floating ? "New window: floating" : "New window: joined Ribbon")
            let behavior = model.data.behavior(for: event.bundle_id)
            if event.floating && behavior.shouldPrompt(global: model.data.promptForNewWindows),
                current?.key != event.key, !queue.contains(where: { $0.key == event.key }), queue.count < 16
            {
                queue.append(event)
                presentNext()
            }
        }
    }

    private func presentNext() {
        guard prompt == nil, !queue.isEmpty else { return }
        guard canPrompt() else {
            queue = []
            return
        }
        let event = queue.removeFirst()
        guard model.data.behavior(for: event.bundle_id).shouldPrompt(global: model.data.promptForNewWindows) else {
            presentNext()
            return
        }
        current = event
        let panel = AppBehaviorPanel(
            contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "RibbonDesk"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(
            rootView: AppBehaviorPrompt(event: event) { [weak self] managed, remember in
                self?.choose(event, managed: managed, remember: remember)
            })
        panel.setContentSize(panel.contentView!.fittingSize)
        panel.center()
        panel.delegate = self
        prompt = panel
        panel.orderFrontRegardless()
    }

    private func choose(_ event: AppBehaviorEvent, managed: Bool, remember: Bool) {
        closePrompt()
        if remember {
            model.setBehavior(managed ? .ribbon : .floating, bundleID: event.bundle_id, name: event.app_name)
        }
        if canPrompt() {
            Task {
                do {
                    _ = try await Task.detached {
                        try Engine.run([
                            "send-cmd", "window", "ribbon", String(event.window_id), String(event.pid),
                            managed ? "add" : "float",
                        ])
                    }.value
                    if !managed { model.record(event, action: "Prompt: kept floating") }
                } catch { model.message = "Couldn’t add the window. " + error.localizedDescription }
                presentNext()
            }
        } else {
            model.record(event, action: "Prompt: kept floating")
            presentNext()
        }
    }

    private func closePrompt() {
        prompt?.delegate = nil
        prompt?.close()
        prompt = nil
        current = nil
    }

    private func dismissPrompts() {
        queue = []
        closePrompt()
    }

    func windowWillClose(_ notification: Notification) {
        if let current { model.record(current, action: "Prompt dismissed; kept floating") }
        prompt = nil
        current = nil
        presentNext()
    }
}
