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
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: supervisor.isRecording ? "record.circle.fill" : "waveform")
        }
    }
}
