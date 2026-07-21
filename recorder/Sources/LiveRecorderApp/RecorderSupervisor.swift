import AppKit
import EventKit
import Foundation
import ServiceManagement

/// Supervises the `recorder` CLI as a child process. Names each meeting from
/// the current calendar event, spawns `recorder --out <named>.jsonl`, and
/// tracks state for the menu bar. Stopping sends SIGTERM so the recorder
/// finalizes its transcript cleanly.
@MainActor
final class RecorderSupervisor: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var meetingName = ""
    @Published private(set) var transcriptURL: URL?
    @Published private(set) var launchAtLogin = false
    /// Echo cancellation (macOS voice-processing). Off by default; toggle in the
    /// menu to test speakers-free. Takes effect on the next Start.
    @Published var aecEnabled = false
    /// Drives the menu-bar waveform animation (0…1 bar height). SymbolEffect
    /// doesn't animate in a MenuBarExtra label, so we cycle this on a timer and
    /// the label re-renders via `variableValue`.
    @Published private(set) var level: Double = 1.0

    private var process: Process?
    private var levelTimer: Timer?

    init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    private func startLevelAnimation() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.level = Double.random(in: 0.2...1.0) }
        }
    }

    private func stopLevelAnimation() {
        levelTimer?.invalidate()
        levelTimer = nil
        level = 1.0
    }

    /// Register/unregister as a macOS Login Item (SMAppService — no permission
    /// prompt, unlike the osascript hack). Needs the app in /Applications.
    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notify("Couldn't change Login Item", error.localizedDescription)
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: - Paths

    var recordingsDir: URL {
        if let env = ProcessInfo.processInfo.environment["LIVE_RECORDER_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ml/myelin/recordings")
    }

    /// The recorder binary: bundled alongside the app, else ~/.local/bin/recorder.
    private func recorderBinary() -> URL? {
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let bundled = dir.appendingPathComponent("recorder")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        let onPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/recorder")
        return FileManager.default.isExecutableFile(atPath: onPath.path) ? onPath : nil
    }

    // MARK: - Control

    func start() {
        guard !isRecording else { return }
        guard let bin = recorderBinary() else {
            notify("Can't find the recorder binary", "Run `make install` or `make app` first.")
            return
        }
        Task {
            var name = await currentMeetingName()
            if name.isEmpty {  // no calendar event → ask, so the name is descriptive
                name = promptForName()
                if name.isEmpty { return }  // cancelled
            }
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let base = name.isEmpty ? "meeting" : sanitize(name)
            let out = recordingsDir.appendingPathComponent("\(base)-\(stamp).jsonl")
            try? FileManager.default.createDirectory(
                at: recordingsDir, withIntermediateDirectories: true)

            let p = Process()
            p.executableURL = bin
            var args = ["--out", out.path]
            if aecEnabled { args.append("--aec") }
            p.arguments = args
            p.terminationHandler = { _ in
                Task { @MainActor in
                    self.isRecording = false
                    self.process = nil
                    self.stopLevelAnimation()
                }
            }
            do {
                try p.run()
                process = p
                isRecording = true
                meetingName = name.isEmpty ? "Untitled meeting" : name
                transcriptURL = out
                startLevelAnimation()
            } catch {
                notify("Couldn't start recording", error.localizedDescription)
            }
        }
    }

    func stop() {
        process?.terminate()  // SIGTERM → recorder finalizes and exits
    }

    func openLiveView() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:8737")!)
    }

    func openTranscriptsFolder() {
        NSWorkspace.shared.open(recordingsDir)
    }

    // MARK: - Naming (calendar, best-effort)

    private func currentMeetingName() async -> String {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else { return "" }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-1800),
            end: now.addingTimeInterval(300),
            calendars: nil)
        let events = store.events(matching: predicate)
        if let live = events.first(where: { $0.startDate <= now && $0.endDate >= now }) {
            return live.title ?? ""
        }
        return events.sorted { $0.startDate < $1.startDate }.first?.title ?? ""
    }

    private func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { allowed.contains($0) }))
        return cleaned.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .prefix(60)
            .description
    }

    /// Ask for a meeting name when the calendar has nothing (ad-hoc call).
    /// Returns "" only if the user cancels (start() then aborts).
    private func promptForName() -> String {
        let alert = NSAlert()
        alert.messageText = "Name this recording"
        alert.informativeText = "No calendar event found — what's this meeting?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "e.g. Acme discovery"
        alert.accessoryView = field
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return "" }
        let entered = field.stringValue.trimmingCharacters(in: .whitespaces)
        return entered.isEmpty ? "Meeting" : entered
    }

    private func notify(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }
}
