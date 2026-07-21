import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⌥⌘R toggles recording, system-wide.
        hotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey)
        ) {
            Task { @MainActor in RecorderSupervisor.shared.toggle() }
        }
    }
}

@main
struct LiveRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var supervisor = RecorderSupervisor.shared

    var body: some Scene {
        MenuBarExtra {
            if supervisor.isRecording {
                Text("● \(supervisor.meetingName)")
                Text("\(supervisor.elapsed) · \(supervisor.lineCount) lines")
                Button("Stop  (⌥⌘R)") { supervisor.stop() }
                Button("Open live transcript") { supervisor.openLiveView() }
            } else {
                Button("Start recording  (⌥⌘R)") { supervisor.start() }
            }
            Divider()
            Button("Open transcripts folder") { supervisor.openTranscriptsFolder() }
            Button(supervisor.aecEnabled ? "✓ Echo cancellation (no headphones)" : "Echo cancellation (no headphones)") {
                supervisor.aecEnabled.toggle()
            }
            Button(supervisor.launchAtLogin ? "✓ Launch at Login" : "Launch at Login") {
                supervisor.toggleLaunchAtLogin()
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            // Static gray waveform when idle; red bars jumping (timer-driven
            // variableValue) while recording.
            Image(systemName: "waveform", variableValue: supervisor.isRecording ? supervisor.level : 1.0)
                .symbolRenderingMode(.palette)
                .foregroundStyle(supervisor.isRecording ? Color.red : Color.primary)
        }
    }
}
