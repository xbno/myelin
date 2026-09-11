import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: UsageStore

    init(store: UsageStore) { self.store = store }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Pace Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(store: store))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func apply(_ on: Bool) {
        do {
            if on {
                if !isEnabled { try SMAppService.mainApp.register() }
            } else if isEnabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Pace: launch at login change failed: \(error.localizedDescription)")
        }
    }
}
