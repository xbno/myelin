import AppKit
import SwiftUI

@main
struct LiveRecorderApp: App {
    @StateObject private var supervisor = RecorderSupervisor()

    var body: some Scene {
        MenuBarExtra {
            if supervisor.isRecording {
                Text("● Recording: \(supervisor.meetingName)")
                Button("Stop") { supervisor.stop() }
                Button("Open live transcript") { supervisor.openLiveView() }
            } else {
                Button("Start recording") { supervisor.start() }
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
            // Always a waveform (not a mic — that reads as the macOS system
            // indicator). Recording: red + bars jump via the timer-driven
            // variableValue. Idle: static gray, full bars.
            Image(systemName: "waveform", variableValue: supervisor.isRecording ? supervisor.level : 1.0)
                .symbolRenderingMode(.palette)
                .foregroundStyle(supervisor.isRecording ? Color.red : Color.primary)
        }
    }
}
