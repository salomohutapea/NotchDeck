import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ModulesSettingsView()
                .tabItem { Label("Modules", systemImage: "square.grid.2x2") }
        }
        .frame(width: 560, height: 560)
    }
}

private struct GeneralSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var screens: [ScreenOption] = ScreenOption.current()

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
            }
            Section("Behaviour") {
                Toggle("Expand on hover", isOn: $settings.expandOnHover)
                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: $settings.hoverDelay, in: 0...1)
                        Text(String(format: "%.2fs", settings.hoverDelay)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                .disabled(!settings.expandOnHover)
                LabeledContent("Collapse delay") {
                    HStack {
                        Slider(value: $settings.collapseDelay, in: 0...1.5)
                        Text(String(format: "%.2fs", settings.collapseDelay)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                Toggle("Show live activities when collapsed", isOn: $settings.showLiveActivities)
                Stepper("Max collapsed icons: \(settings.maxCompactIcons)", value: $settings.maxCompactIcons, in: 0...4)
                Text("Fewer icons leave more of the menu bar visible next to the notch. macOS itself hides menu items behind the physical notch.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("When something happens", selection: $settings.peekStyle) {
                    ForEach(PeekStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Gestures") {
                Toggle("Swipe gestures on the notch", isOn: $settings.gesturesEnabled)
                Text("Swipe up to close, swipe sideways to switch tabs, swipe down on the collapsed notch to open. "
                     + "Vertical swipes over scrollable content scroll it instead; use the tab row to close.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Animation", selection: $settings.animationStyle) {
                    ForEach(AnimationStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Extra width") {
                    HStack {
                        Slider(value: $settings.notchExtraWidth, in: AppSettings.extraWidthRange, step: 1)
                        Text("\(Int(settings.notchExtraWidth)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("Extra height") {
                    HStack {
                        Slider(value: $settings.notchExtraHeight, in: AppSettings.extraHeightRange, step: 1)
                        Text("\(Int(settings.notchExtraHeight)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                HStack {
                    Text("Applies to the collapsed shape on displays with a notch.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") {
                        settings.notchExtraWidth = 0
                        settings.notchExtraHeight = 0
                    }
                    .disabled(settings.notchExtraWidth == 0 && settings.notchExtraHeight == 0)
                }
            }
            Section("Displays") {
                Picker("Show on", selection: displayBinding) {
                    Text("Notched display (main if none)").tag("notchedOnly")
                    Text("Main display").tag("mainScreen")
                    Text("All displays").tag("allScreens")
                    Divider()
                    ForEach(screens) { Text($0.name).tag("display:\($0.id)") }
                    if let missing = disconnectedSelection {
                        Text("\(missing) (disconnected)").tag(displayBinding.wrappedValue)
                    }
                }
                Toggle("Hide in full-screen apps", isOn: $settings.hideInFullscreen)
                Text("Displays without a notch show a floating capsule.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = ScreenOption.current()
        }
    }

    private var displayBinding: Binding<String> {
        Binding(
            get: {
                switch settings.displayMode {
                case .notchedOnly: return "notchedOnly"
                case .mainScreen: return "mainScreen"
                case .allScreens: return "allScreens"
                case .specific(let id, let name):
                    // Prefer the connected screen with the same name when the ID changed.
                    if let s = screens.first(where: { $0.id == id }) ?? screens.first(where: { $0.name == name }) {
                        return "display:\(s.id)"
                    }
                    return "missing:\(id)"
                }
            },
            set: { key in
                switch key {
                case "notchedOnly": settings.displayMode = .notchedOnly
                case "mainScreen": settings.displayMode = .mainScreen
                case "allScreens": settings.displayMode = .allScreens
                default:
                    if key.hasPrefix("display:"), let id = UInt32(key.dropFirst("display:".count)),
                       let s = screens.first(where: { $0.id == id }) {
                        settings.displayMode = .specific(id: id, name: s.name)
                    }
                }
            }
        )
    }

    /// Name of the chosen display when it is not currently connected.
    private var disconnectedSelection: String? {
        guard case .specific(_, let name) = settings.displayMode,
              displayBinding.wrappedValue.hasPrefix("missing:") else { return nil }
        return name
    }
}

private struct ScreenOption: Identifiable {
    let id: UInt32
    let name: String

    static func current() -> [ScreenOption] {
        NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return ScreenOption(id: n.uint32Value, name: screen.localizedName)
        }
    }
}

private struct ModulesSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    private let registry = ModuleRegistry.shared
    @State private var order: [ModuleID] = ModuleID.allCases

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(order) { id in
                    HStack(spacing: 10) {
                        Image(systemName: id.systemImage).frame(width: 22)
                        Text(id.title)
                        Spacer()
                        Toggle("Show as tab", isOn: tabBinding(for: id))
                            .toggleStyle(.checkbox)
                            .disabled(!settings.enabledModules.contains(id))
                            .help("Show this module as its own tab. Hidden modules keep running.")
                        Toggle("", isOn: binding(for: id)).labelsHidden().toggleStyle(.switch)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { from, to in
                    order.move(fromOffsets: from, toOffset: to)
                    commit(enabled: Set(settings.enabledModules))
                }
            }
            .frame(height: 6 * 34 + 24)
            Text("Drag to reorder. Order sets the tab order. Modules without a tab keep running and still peek.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 6)

            Form {
                ForEach(settings.enabledModules) { id in
                    if let view = registry.module(for: id).settings() {
                        Section(id.title) { view }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { syncOrder() }
    }

    private func binding(for id: ModuleID) -> Binding<Bool> {
        Binding(
            get: { settings.enabledModules.contains(id) },
            set: { on in
                var set = Set(settings.enabledModules)
                if on { set.insert(id) } else { set.remove(id) }
                commit(enabled: set)
            }
        )
    }

    private func tabBinding(for id: ModuleID) -> Binding<Bool> {
        Binding(
            get: { !settings.hiddenTabs.contains(id) },
            set: { on in
                if on { settings.hiddenTabs.remove(id) } else { settings.hiddenTabs.insert(id) }
            }
        )
    }

    private func commit(enabled: Set<ModuleID>) {
        settings.enabledModules = order.filter { enabled.contains($0) }
    }

    private func syncOrder() {
        let enabled = settings.enabledModules
        order = enabled + ModuleID.allCases.filter { !enabled.contains($0) }
    }
}
