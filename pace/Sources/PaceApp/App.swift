import AppKit
import PaceCore

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no dock icon
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let provider: UsageProvider = DebugProvider.fromEnvironment() ?? AnthropicProvider()
        store = UsageStore(provider: provider)
        settingsWindow = SettingsWindowController(store: store)
        statusItem = StatusItemController(store: store)
        statusItem.openSettings = { [weak self] in self?.settingsWindow.show() }
        LaunchAtLogin.apply(store.settings.launchAtLogin)
        store.start()
    }
}
