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
            Button(supervisor.launchAtLogin ? "✓ Launch at Login" : "Launch at Login") {
                supervisor.toggleLaunchAtLogin()
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            // recording: red waveform with the bars animating (variableColor);
            // idle: a plain monochrome mic. The motion is the on/off tell even
            // if the menu bar monochromes the red.
            Image(systemName: supervisor.isRecording ? "waveform" : "mic")
                .symbolRenderingMode(.palette)
                .foregroundStyle(supervisor.isRecording ? Color.red : Color.primary)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: supervisor.isRecording)
        }
    }
}
