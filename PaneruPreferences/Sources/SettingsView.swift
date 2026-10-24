import AppKit
import SwiftUI

struct SettingsView: View {
    static let width: CGFloat = 720
    @ObservedObject var model: SettingsModel
    private let accent = Color(red: 0.20, green: 0.53, blue: 0.62)
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    private let shortcuts = [
        ("Previous / next window", "H / L or ← / →"),
        ("Move window left / right", "J / K"),
        ("Half width", "2"),
        ("Full width", "0 / F"),
        ("Toggle half / full", "R"),
        ("Toggle floating", "T"),
        ("First / last window", "Home / End"),
        ("Ribbon Overview", "O"),
        ("Open settings", "S"),
        ("Pause window management", "Q")
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                header.padding(.bottom, 4)
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 8) {
                        scrolling
                        snapping
                    }.frame(width: 396)
                    VStack(spacing: 8) {
                        general
                        windowManagement
                        appearance
                        shortcutReference
                        feelPresets
                    }.frame(maxWidth: .infinity)
                }.disabled(model.engineBusy)
            }.padding(12)
            Divider()
            footer
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 12))
        .controlSize(.small)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Panes().stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .padding(5).frame(width: 30, height: 30)
                .background(accent.gradient, in: RoundedRectangle(cornerRadius: 8))
            Text("RibbonDesk").font(.system(size: 17, weight: .semibold, design: .rounded))
            Text("Settings").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("v\(version) · build \(build)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .accessibilityLabel("RibbonDesk version \(version), build \(build)")
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(accent).frame(width: 4, height: 4)
                Text("Live settings").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }.padding(.horizontal, 8).padding(.vertical, 4)
                .background(accent.opacity(0.12), in: Capsule())
        }
    }

    private var general: some View {
        section("General") {
            toggleRow("This Desktop", detail: model.desktop?.name ?? "Unavailable", value: $model.currentDesktopEnabled)
                .disabled(model.desktop == nil)
                .help("Enable window management, gestures, and shortcuts on this Desktop.")
            toggleRow("Launch at login", detail: "RibbonDesk", value: $model.launchAtLogin)
                .accessibilityHint("Starts RibbonDesk automatically when you log in.")
            HStack(spacing: 10) {
                rowLabel("Activate on")
                Picker("Activate windows", selection: $model.focusMode) {
                    Text("Mouse over").tag(FocusMode.hover)
                    Text("Click").tag(FocusMode.click)
                }.pickerStyle(.segmented).labelsHidden()
                    .help("Mouse over activates on hover. Click mode activates on the first click; click again to interact.")
            }.frame(height: 22)
            if !model.accessibilityGranted && (model.focusMode == .click || model.failed) {
                Button("Allow Click Mode…", action: model.allowClickMode)
                caption("Allow Accessibility, then select Click again.")
            }
            if model.loginApprovalRequired {
                Button("Approve in Login Items…", action: LoginItem.openSettings)
            }
        }
    }

    private var scrolling: some View {
        let settings = model.draft
        return section("Scrolling") {
            toggleRow("Three-finger paging", detail: "One snap", value: $model.threeFingerPaging)
            caption("On: every three-finger swipe advances one window alignment, including apps with fixed widths. Only Snap animation applies; other sliders still tune Control–Option scrolling. Off restores free scrolling.")
                .padding(.bottom, 5)
            SettingsSliderRow("Scroll speed", value: $model.speed, range: 0.2...1.5, step: 0.05,
                              readout: String(format: "%.2f×", settings.speed),
                              help: "Free-scroll movement while your fingers are down. 0.20× gives the finest control; 1.50× moves farthest for the same swipe.")
            SettingsSliderRow("Momentum", value: $model.momentum, range: 0...3, step: 0.1,
                              readout: settings.momentum == 0 ? "Off" : String(format: "%.2f×", settings.momentum),
                              help: "Free-scroll coasting after you lift your fingers. 0 stops immediately and disables free-scroll snapping; 3× gives the longest coast at the same decay.")
            SettingsSliderRow("Momentum decay", value: $model.momentumDecay, range: 1...100, step: 1,
                              readout: String(format: "%.2f", settings.momentumDecay),
                              help: "How quickly coasting fades. 1 lets momentum linger; 100 brakes it fastest. The initial flick speed stays the same.", logarithmic: true)
        }
    }

    private var windowManagement: some View {
        section("Window management", detail: model.engineBusy ? "Updating…" : (model.engineRunning ? "Running" : "Paused")) {
            HStack(spacing: 6) {
                Button(model.engineRunning ? "Pause" : "Start") { model.toggleEngineAction?() }
                    .accessibilityLabel(model.engineRunning ? "Pause Window Management" : "Start Window Management")
                    .disabled(!model.currentDesktopEnabled)
                Button("Restart") { model.restartEngineAction?() }
                    .accessibilityLabel("Restart RibbonDesk")
                    .disabled(!model.currentDesktopEnabled)
                Button("Overview") { model.overviewAction?() }
                    .disabled(!model.engineRunning || !model.currentDesktopEnabled)
                    .help("See and rearrange the whole ribbon (Control–Option–O).")
                Spacer(minLength: 0)
                Button("Quit") { model.quitAction?() }
                    .accessibilityLabel("Quit RibbonDesk")
            }.frame(height: 22).disabled(model.applying || model.engineBusy)
            toggleRow("Overview animation", detail: "Off switches instantly", value: $model.overviewAnimation)
            if !model.currentDesktopEnabled { caption("Enable This Desktop to start window management here.") }
        }
    }

    private var snapping: some View {
        let settings = model.draft
        return section("Snapping") {
            toggleRow("Full-width windows", detail: "", value: $model.snapFullWidth)
            toggleRow("Half-width windows", detail: "Either edge", value: $model.snapHalfWidth)
            SettingsSliderRow("Flick threshold", value: $model.snapSpeed, range: 0...3, step: 0.1,
                              readout: settings.snapSpeed == 0 ? "Off" : String(format: "%.2f/s", settings.snapSpeed),
                              help: "Minimum speed for a forward snap (screens/second). Near 0 allows gentle flicks; 3 requires a fast flick. At 0, free-scroll snapping is off.")
            SettingsSliderRow("Snap visibility", value: $model.snapVisible, range: 0.25...0.95, step: 0.05,
                              readout: String(format: "%.0f%%", settings.snapVisible * 100),
                              help: "How much of the destination window your coast is predicted to reveal. 25% snaps with less travel; 95% needs almost the whole window revealed.")
            SettingsSliderRow("Snap animation", value: $model.snapAnimation, range: 0.2...4, step: 0.1,
                              readout: String(format: "%.2f×", settings.snapAnimation),
                              help: "How quickly a triggered snap settles. 0.20× glides slowly into place; 4× settles fastest. The flick needed to trigger it stays the same.")
            Divider().padding(.vertical, 4)
            toggleRow("Snap back", detail: "Return on small swipe", value: $model.snapBack)
                .help("Off keeps your swipe progress: snapping never pulls backward. On lets small swipes return to their starting alignment.")
            SettingsSliderRow("Exit distance", value: $model.snapExitDistance, range: 0...0.5, step: 0.01,
                              readout: String(format: "%.0f%%", settings.snapExitDistance * 100),
                              help: "Used when Snap back is on. 0% removes the return zone; 50% requires half a screen of predicted travel to escape. A faster swipe or longer drag helps.")
                .disabled(!model.snapBack)
            caption(model.snapBack ? "Small swipes may return until they clear the exit distance." : "Snap back is off: small swipes keep their progress.")
                .padding(.top, 2)
        }
    }

    private var feelPresets: some View {
        section("Feel presets") {
            HStack(spacing: 6) {
                TextField("Preset name", text: $model.presetName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Feel preset name")
                    .onSubmit { model.savePreset() }
                Button("Save Current", action: model.savePreset)
                    .disabled(model.presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.frame(height: 24)
            HStack(spacing: 6) {
                Picker("Saved feel preset", selection: $model.selectedPresetID) {
                    Text("Choose a preset…").tag("")
                    ForEach(model.presets) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(maxWidth: .infinity)
                Button("Load", action: model.loadPreset).disabled(model.selectedPresetID.isEmpty)
                Button(action: model.deletePreset) { Image(systemName: "trash") }
                    .accessibilityLabel("Delete selected feel preset")
                    .disabled(model.selectedPresetID.isEmpty)
            }.frame(height: 24)
            caption("Saves scrolling + snapping. Reuse a name to update it.")
                .padding(.top, 2)
        }
    }

    private var appearance: some View {
        section("Appearance") {
            SettingsSliderRow("Window gap", value: $model.gap, range: 0...24, step: 2,
                              readout: "\(model.draft.gap) pt",
                              help: "0 pt puts windows edge to edge; 24 pt gives the widest gap. Changes briefly refresh the layout.")
            HStack(spacing: 10) {
                rowLabel("Window outline")
                HStack(spacing: 8) {
                    OutlineColorWell(color: $model.borderColor).frame(width: 28, height: 20)
                    TextField("#RRGGBB", text: $model.borderColorHex)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 80)
                        .accessibilityLabel("Outline color hex")
                        .onSubmit { model.commitBorderColor() }
                }.disabled(!model.borderEnabled)
                    .help("Choose a color or enter six hex digits. Complete colors apply automatically.")
                Spacer(minLength: 0)
                Toggle("Active window outline", isOn: $model.borderEnabled).labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel("Active window outline")
            }.frame(height: 22)
        }
    }

    private var shortcutReference: some View {
        section("Shortcuts", detail: "Control + Option") {
            VStack(spacing: 0) {
                ForEach(shortcuts, id: \.0) { item in
                    HStack(spacing: 10) {
                        Text(item.0).font(.system(size: 11))
                        Spacer()
                        Text(item.1).font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }.frame(height: 17)
                }
            }
            caption("⌘-click a window to bring it fully into view.").padding(.top, 2)
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            if model.applying { ProgressView().controlSize(.mini) }
            else { Image(systemName: model.failed ? "exclamationmark.circle" : "checkmark.circle") }
            Text(model.message).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Button("Reset Defaults", action: model.reset).foregroundStyle(.primary)
                .disabled(model.engineBusy)
        }
        .font(.system(size: 10))
        .foregroundStyle(model.failed ? Color.red : Color.secondary)
        .frame(height: 28)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func section<Content: View>(_ title: String, detail: String? = nil,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
                Spacer()
                if let detail { Text(detail).font(.system(size: 10)) }
            }.foregroundStyle(.secondary).padding(.bottom, 3)
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.05)))
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title).frame(width: SettingsSliderRow.labelWidth, alignment: .leading)
    }

    private func toggleRow(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Text(title).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 0)
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(title)
        }.frame(height: 22)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSliderRow: View {
    static let labelWidth: CGFloat = 110
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let readout: String
    let help: String
    let logarithmic: Bool

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, readout: String, help: String, logarithmic: Bool = false) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.readout = readout
        self.help = help
        self.logarithmic = logarithmic
    }

    private var trackRange: ClosedRange<Double> {
        logarithmic ? log(range.lowerBound)...log(range.upperBound) : range
    }

    private var trackValue: Binding<Double> {
        Binding(get: { logarithmic ? log(max(range.lowerBound, value)) : value },
                set: { value = logarithmic ? exp($0) : $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(title).frame(width: Self.labelWidth, alignment: .leading)
                // Continuous native tracks avoid dense tick marks. Accessibility
                // adjustments retain predictable steps without blocking arrow keys.
                Slider(value: trackValue, in: trackRange)
                    .accessibilityLabel(title)
                    .accessibilityValue(readout)
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: value = min(range.upperBound, value + step)
                        case .decrement: value = max(range.lowerBound, value - step)
                        @unknown default: break
                        }
                    }
                Text(readout).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }.frame(height: 22)
            Text(help).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 4).help(help)
    }
}

private struct OutlineColorWell: NSViewRepresentable {
    @Binding var color: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell()
        well.colorWellStyle = .minimal
        if #available(macOS 14, *) { well.supportsAlpha = false }
        well.setAccessibilityLabel("Outline color")
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.parent = self
        let next = NSColor(color)
        if well.color != next { well.color = next }
        well.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var parent: OutlineColorWell
        init(_ parent: OutlineColorWell) { self.parent = parent }
        @objc func colorChanged(_ sender: NSColorWell) { parent.color = Color(nsColor: sender.color) }
    }
}

private struct Panes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scale = min(rect.width / 22, rect.height / 20)
        let origin = CGPoint(x: rect.midX - 11 * scale, y: rect.midY - 10 * scale)
        for x in [2.0, 9.0, 16.0] {
            let frame = CGRect(x: origin.x + x * scale, y: origin.y + 3 * scale, width: 4 * scale, height: 14 * scale)
            path.addRoundedRect(in: frame, cornerSize: CGSize(width: scale, height: scale))
        }
        return path
    }
}
