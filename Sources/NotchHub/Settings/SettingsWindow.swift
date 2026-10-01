import AppKit
import SwiftUI

/// The Settings window: a standard titled NSWindow, one section per module.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let hub: HubStore
    private let engine: PomodoroEngine

    init(hub: HubStore, engine: PomodoroEngine) {
        self.hub = hub
        self.engine = engine
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "NotchHub Settings"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentMinSize = NSSize(width: 460, height: 400)
            w.contentView = NSHostingView(rootView: SettingsRootView(hub: hub, engine: engine))
            w.center()
            window = w
        }
        // A standard window needs the app active to take keyboard input. This is the only place
        // NotchHub activates itself; the notch panel never does.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsRootView: View {
    @ObservedObject var hub: HubStore
    @ObservedObject var engine: PomodoroEngine

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $engine.settings.launchAtLogin)
                LabeledContent("Start / pause focus", value: "⌃⌥P")
                LabeledContent("Open / close the notch", value: "⌃⌥N")
                VStack(alignment: .leading) {
                    Slider(value: $hub.settings.idleWidthOverride, in: 0...300, step: 2) {
                        Text("Idle notch width")
                    }
                    Text(hub.settings.idleWidthOverride > 0
                         ? "\(Int(hub.settings.idleWidthOverride)) pt (0 = match the notch, \(Int(hub.notchWidth)) pt)"
                         : "Matches the notch (\(Int(hub.notchWidth)) pt)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Toggle("Show on all displays", isOn: $hub.settings.showOnAllDisplays)
                    .disabled(true)
                Text("v2 targets the built-in (notched) screen only.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(hub.modules.map(\.id), id: \.self) { id in
                if let module = hub.module(id) {
                    Section {
                        Toggle("Enabled", isOn: Binding(get: { hub.isEnabled(id) },
                                                        set: { hub.setEnabled(id, $0) }))
                        if hub.isEnabled(id) {
                            module.settingsView
                        }
                    } header: {
                        Label(module.title, systemImage: module.systemImage)
                    }
                }
            }
            Section("Data") {
                Text("Everything is stored in the UserDefaults domain com.pritesh.notchhub.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 400)
    }
}
