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
        // The debug provider stands in for the whole set when it is switched on.
        let providers: [UsageProvider] = DebugProvider.fromEnvironment().map { [$0] }
            ?? [AnthropicProvider(), CodexProvider()]
        store = UsageStore(providers: providers)
        settingsWindow = SettingsWindowController(store: store)
        statusItem = StatusItemController(store: store)
        statusItem.openSettings = { [weak self] in self?.settingsWindow.show() }
        LaunchAtLogin.apply(store.settings.launchAtLogin)
        store.start()
    }
}
