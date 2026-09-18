import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⌥⌘R toggles recording; ⌥⌘C opens Cowork with /live-recorder prefilled.
        HotKeyCenter.shared.register(
            keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey)
        ) {
            Task { @MainActor in RecorderSupervisor.shared.toggle() }
        }
        HotKeyCenter.shared.register(
            keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | optionKey)
        ) {
            Task { @MainActor in RecorderSupervisor.shared.askClaudeAboutCall() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quit must not orphan a live recording — SIGTERM the child so it
        // finalizes its transcript. (The recorder also self-stops on parent
        // death, so ungraceful exits are covered too.)
        MainActor.assumeIsolated { RecorderSupervisor.shared.stop() }
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
            Button("Ask Claude about this call  (⌥⌘C)") { supervisor.askClaudeAboutCall() }
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
            //
            // Monochrome: one colour (red recording / primary idle), so palette
            // mode added nothing. The Sep 16 "icon vanished after a rebuild"
            // was NOT a rendering bug: the notched built-in display ran out of
            // menu bar room and macOS hid the leftmost items — a relaunched
            // item with no saved position always lands leftmost. Pinning it to
            // the right fixed it (MenuBarExtra's autosave name is Item-0):
            //   defaults write com.geoff.live-recorder.app \
            //     "NSStatusItem Preferred Position Item-0" -float 3000
            Image(systemName: "waveform", variableValue: supervisor.isRecording ? supervisor.level : 1.0)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(supervisor.isRecording ? Color.red : Color.primary)
        }
    }
}
