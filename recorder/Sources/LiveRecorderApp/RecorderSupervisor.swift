import AppKit
import ApplicationServices
import EventKit
import Foundation
import ServiceManagement

/// Supervises the `recorder` CLI as a child process. Confirms each meeting's
/// name via a dialog prefilled from the current calendar event, spawns
/// `recorder --out <stamp>-<name>.jsonl`, and tracks state for the menu bar.
/// Stopping sends SIGTERM so the recorder finalizes its transcript cleanly.
@MainActor
final class RecorderSupervisor: ObservableObject {
    static let shared = RecorderSupervisor()

    @Published private(set) var isRecording = false
    @Published private(set) var meetingName = ""
    @Published private(set) var transcriptURL: URL?
    @Published private(set) var launchAtLogin = false
    /// Live status shown in the menu while recording.
    @Published private(set) var elapsed = "0:00"
    @Published private(set) var lineCount = 0
    /// Echo cancellation (macOS voice-processing) — OFF by default: the usual
    /// setup is headphones, where AEC only degrades the mic. Toggle on in the
    /// menu for speakers-free calls (verified to strip ~all system-audio echo
    /// from the mic). Effective next Start.
    @Published var aecEnabled = false
    /// Drives the menu-bar waveform animation (0…1 bar height). SymbolEffect
    /// doesn't animate in a MenuBarExtra label, so we cycle this on a timer and
    /// the label re-renders via `variableValue`.
    @Published private(set) var level: Double = 1.0
    /// Where transcripts are written. Set from the menu; see the Paths section.
    @Published private(set) var recordingsDir: URL

    private var process: Process?
    private var levelTimer: Timer?
    private var statusTimer: Timer?
    private var recordingStart: Date?
    private var lastActivity: Date?
    private var lastLineCount = 0
    /// Auto-stop after this many seconds with no NEW transcript lines — catches
    /// "forgot to stop after the call" without cutting off a long active meeting
    /// (an inactivity timeout, not a hard cap).
    private let idleAutoStop: TimeInterval = 15 * 60
    /// How long a stop prompt (idle, or ⌥⌘R) waits for an answer.
    private let stopPromptGrace: TimeInterval = 60
    private var stopPromptUp = false
    private var axTick = 0
    private var axProbeRan = false
    private var axProbePrompted = false

    init() {
        recordingsDir = Self.resolvedRecordingsDir()
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func toggle() { isRecording ? promptStopFromHotkey() : start() }

    /// True while the name dialog is up. A second ⌥⌘R during the prompt used
    /// to stack a second modal session on top of the first — the visible
    /// dialog's buttons then belonged to the wrong session and nothing could
    /// be clicked away.
    private var namePromptUp = false

    private func startStatusTimer() {
        recordingStart = Date()
        lastActivity = Date()
        lastLineCount = 0
        axTick = 0
        axProbeRan = false
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
        recordingStart = nil
        elapsed = "0:00"
        lineCount = 0
    }

    private func updateStatus() {
        if let start = recordingStart {
            let s = Int(Date().timeIntervalSince(start))
            elapsed = String(format: "%d:%02d", s / 60, s % 60)
        }
        if let n = transcriptLineCount() { lineCount = n }
        if lineCount > lastLineCount {  // new speech → still active
            lastLineCount = lineCount
            lastActivity = Date()
        } else if !stopPromptUp, let last = lastActivity,
                  Date().timeIntervalSince(last) >= idleAutoStop {
            promptStillRecording()  // quiet for 15 min — ask before assuming the call's over
        }
        axTick += 1
        if axTick % 45 == 0 { maybeRunAXProbe() }
    }

    /// Lines in the live transcript, nil when it can't be read.
    private func transcriptLineCount() -> Int? {
        guard let url = transcriptURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").count
    }

    /// Quiet for `idleAutoStop`: ask before stopping. A listen-only call can go
    /// quiet for a long stretch (screen share, a pause), and stopping outright
    /// lost the rest of it. No answer stops; new transcript lines while the
    /// prompt is up mean the call is still going, so they count as Keep.
    private func promptStillRecording() {
        confirmStop(
            title: "Still recording \u{201C}\(meetingName)\u{201D}?",
            detail: "No new speech for \(Int(idleAutoStop / 60)) minutes. "
                + "Recording stops in \(Int(stopPromptGrace)) seconds unless you keep it.",
            timeoutStops: true, growthKeeps: true)
    }

    /// ⌥⌘R while recording: ask, because the hotkey fires from any app and a
    /// stray press used to end the recording with nothing on screen. Enter
    /// keeps, no answer keeps; a deliberate stop is one click.
    private func promptStopFromHotkey() {
        confirmStop(
            title: "Stop recording \u{201C}\(meetingName)\u{201D}?",
            detail: "⌥⌘R was pressed. Recording continues in \(Int(stopPromptGrace)) seconds "
                + "unless you stop it.",
            timeoutStops: false, growthKeeps: false)
    }

    /// One dialog for both: Keep Recording (Enter) resets the idle clock, Stop
    /// stops. No answer within `stopPromptGrace` resolves per `timeoutStops`;
    /// with `growthKeeps`, new transcript lines while it is up count as Keep.
    private func confirmStop(title: String, detail: String, timeoutStops: Bool, growthKeeps: Bool) {
        guard !stopPromptUp else { return }
        stopPromptUp = true
        NSApp.activate(ignoringOtherApps: true)
        // Host the modal from a run-loop callout, not from a Task — see start()
        // for why a Task-hosted runModal misbehaves.
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                guard self.isRecording else { self.stopPromptUp = false; return }
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = detail
                let buttons = [alert.addButton(withTitle: "Keep Recording"),
                               alert.addButton(withTitle: "Stop")]
                // Tab moves the Enter target (the blue button) to the other
                // button, so Tab, Enter stops without the mouse. Alert buttons
                // aren't in the Tab loop unless Full Keyboard Access is on, and
                // even then Enter always fires the default button. Esc is Keep.
                let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.window === alert.window else { return event }
                    switch event.keyCode {
                    case 48:  // Tab
                        let other = alert.window.defaultButtonCell === buttons[0].cell ? buttons[1] : buttons[0]
                        alert.window.defaultButtonCell = other.cell as? NSButtonCell
                    case 53:  // Esc
                        buttons[0].performClick(nil)
                    default:
                        return event
                    }
                    return nil
                }
                let deadline = Date().addingTimeInterval(self.stopPromptGrace)
                let linesAtPrompt = self.lineCount
                let onTimeout: NSApplication.ModalResponse =
                    timeoutStops ? .alertSecondButtonReturn : .alertFirstButtonReturn
                // .common so it fires inside the modal session (as stop()'s killer
                // does); stopModal ends runModal with the given button's code.
                let watch = Timer(timeInterval: 1, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        if growthKeeps, (self.transcriptLineCount() ?? linesAtPrompt) > linesAtPrompt {
                            NSApp.stopModal(withCode: .alertFirstButtonReturn)  // speech resumed
                        } else if Date() >= deadline {
                            NSApp.stopModal(withCode: onTimeout)  // nobody answered
                        }
                    }
                }
                RunLoop.main.add(watch, forMode: .common)
                let response = alert.runModal()
                watch.invalidate()
                if let keys { NSEvent.removeMonitor(keys) }
                self.stopPromptUp = false
                if response == .alertFirstButtonReturn {
                    self.lastActivity = Date()
                } else {
                    self.stop()
                }
            }
        }
    }

    /// One-time R&D capture for native-Teams speaker naming: while a recording
    /// is live and the Teams app is running, snapshot its accessibility tree
    /// (roster + which attributes toggle as people speak) into
    /// `<recordings>/.ax-probe.log`. At most once per recording. Needs
    /// Accessibility for THIS app — prompts once per app run to register it in
    /// System Settings; until granted this is a silent no-op every 45s.
    private func maybeRunAXProbe() {
        guard isRecording, !axProbeRan else { return }
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.microsoft.teams2"
        }) else { return }
        guard AXIsProcessTrusted() else {
            if !axProbePrompted {
                axProbePrompted = true
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
            }
            return
        }
        guard let bin = recorderBinary() else { return }
        axProbeRan = true
        let logURL = recordingsDir.appendingPathComponent(".ax-probe.log")
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        _ = try? handle.seekToEnd()
        handle.write(Data("\n=== AX probe \(ISO8601DateFormatter().string(from: Date())) ===\n".utf8))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c",
            "'\(bin.path)' --ax-dump --app com.microsoft.teams2; "
            + "'\(bin.path)' --ax-watch --app com.microsoft.teams2"]
        p.standardOutput = handle
        p.standardError = handle
        p.terminationHandler = { _ in try? handle.close() }
        try? p.run()
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

    /// One line, one absolute path: the folder every transcript goes in. The
    /// menu writes it; the `recorder` CLI and the pull skill read the same
    /// file, so all three agree without any of them hardcoding a checkout.
    private static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/live-recorder/recordings-dir")

    /// $LIVE_RECORDER_DIR (one-off override) → the saved folder → the checkout
    /// this app was built from (baked in by `make app`) → ~/recordings.
    private static func resolvedRecordingsDir() -> URL {
        if let env = ProcessInfo.processInfo.environment["LIVE_RECORDER_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        if let saved = savedRecordingsDir() { return saved }
        if let baked = Bundle.main.object(forInfoDictionaryKey: "LRDefaultRecordingsDir")
            as? String, !baked.isEmpty {
            return URL(fileURLWithPath: baked)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("recordings")
    }

    private static func savedRecordingsDir() -> URL? {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Nothing chosen yet — the app asks once, at first launch.
    var recordingsDirUnset: Bool {
        let env = ProcessInfo.processInfo.environment["LIVE_RECORDER_DIR"] ?? ""
        return env.isEmpty && Self.savedRecordingsDir() == nil
    }

    /// Last two path components, for the menu item.
    var recordingsDirLabel: String {
        let parts = recordingsDir.pathComponents.suffix(2)
        return parts.joined(separator: "/")
    }

    /// Send transcripts to `dir` from now on: create it, remember it, and
    /// update the menu. Returns a message to show the user, nil on success.
    private func useRecordingsDir(_ dir: URL) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.createDirectory(
                at: Self.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (dir.path + "\n").write(to: Self.configURL, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        recordingsDir = dir
        return nil
    }

    /// Type where transcripts go. Shown from the menu, and once at first launch
    /// so a fresh install is pointed somewhere real before the first call. The
    /// folder is created if it doesn't exist.
    func promptForRecordingsDir(firstRun: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = firstRun ? "Where should recordings go?" : "Recordings folder"
        alert.informativeText = firstRun
            ? "Type a full path. It's created if it doesn't exist, and you can change it "
                + "any time from the menu."
            : "Type a full path. It's created if it doesn't exist. Takes effect on your "
                + "next recording."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = recordingsDir.path
        alert.accessoryView = field
        alert.addButton(withTitle: "Use This Folder")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let typed = (field.stringValue.trimmingCharacters(in: .whitespaces) as NSString)
            .expandingTildeInPath
        guard typed.hasPrefix("/") else {
            notify("That's not a full path", "Start it with / or ~ — e.g. ~/myelin/recordings.")
            return
        }
        if let problem = useRecordingsDir(URL(fileURLWithPath: typed)) {
            notify("Couldn't use that folder", problem)
        }
    }

    /// Append handle to `<recordings>/.recorder.log`, truncated when it grows
    /// past 2 MB. Owner-only, like the transcripts.
    private func openRecorderLog() -> FileHandle? {
        let url = recordingsDir.appendingPathComponent(".recorder.log")
        let fm = FileManager.default
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 2_000_000 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
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
        guard !isRecording, !namePromptUp else { return }
        guard let bin = recorderBinary() else {
            notify("Can't find the recorder binary", "Run `make install` or `make app` first.")
            return
        }
        // Activate now, while still handling the user's hotkey/menu action:
        // cooperative activation honours this, and the app is then already
        // frontmost when the name dialog appears after the calendar lookup.
        NSApp.activate(ignoringOtherApps: true)
        Task {
            namePromptUp = true
            defer { namePromptUp = false }
            // Always confirm the name — prefilled from the live calendar event
            // so Enter accepts it, editable when the event is wrong or missing.
            let suggestion = await currentMeetingName()
            // Run the modal from a run-loop callout, NOT from this Task. A Task
            // body is a GCD main-queue block, and a modal loop nested inside one
            // cannot drain the main queue — AppKit's key-window/field-editor
            // plumbing rides on it, so the dialog showed but the field never
            // took the cursor, and any queued main-queue work (the old focus
            // retries) fired in a burst after the modal ended, re-showing the
            // closed alert as a dead "zombie" dialog. Verified Sep 16 with a
            // probe app: Task-hosted runModal → no cursor; run-loop-hosted → OK.
            let name: String? = await withCheckedContinuation { cont in
                RunLoop.main.perform {
                    MainActor.assumeIsolated {
                        cont.resume(returning: self.promptForName(suggestion: suggestion))
                    }
                }
            }
            guard let name else { return }  // cancelled
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let base = sanitize(name)
            // Timestamp first so the recordings dir sorts chronologically.
            let out = recordingsDir.appendingPathComponent(
                "\(stamp)-\(base.isEmpty ? "meeting" : base).jsonl")
            try? FileManager.default.createDirectory(
                at: recordingsDir, withIntermediateDirectories: true)

            let p = Process()
            p.executableURL = bin
            var args = ["--out", out.path]
            if aecEnabled { args.append("--aec") }
            p.arguments = args
            // Capture the child's stderr (status lines, tap rebuilds, errors) —
            // otherwise it all goes to /dev/null and a capture stall leaves no
            // trace to debug with (the July 27 capture stall).
            let log = openRecorderLog()
            log?.write(Data("\n=== \(stamp) start \(out.lastPathComponent) ===\n".utf8))
            if let log {
                p.standardOutput = log
                p.standardError = log
            }
            p.terminationHandler = { _ in
                Task { @MainActor in
                    try? log?.close()
                    self.isRecording = false
                    self.process = nil
                    self.stopLevelAnimation()
                    self.stopStatusTimer()
                }
            }
            do {
                try p.run()
                process = p
                isRecording = true
                meetingName = name
                transcriptURL = out
                startLevelAnimation()
                startStatusTimer()
            } catch {
                notify("Couldn't start recording", error.localizedDescription)
            }
        }
    }

    func stop() {
        guard let p = process else { return }
        lastActivity = Date()  // no idle prompt while the child finalizes
        p.terminate()  // SIGTERM → recorder finalizes and exits
        // A wedged finalize used to trap the whole app: the child never exits,
        // so terminationHandler never runs, isRecording stays true, and Start
        // refuses forever (Sep 21 — CoreAudio teardown deadlock). Escalate
        // rather than hang. Every transcript line is fsync'd as it is written,
        // so a kill costs nothing that was already captured. Run-loop timer,
        // not DispatchQueue.main: a modal run loop would starve a GCD block.
        let killer = Timer(timeInterval: 5, repeats: false) { _ in
            if p.isRunning { _ = kill(p.processIdentifier, SIGKILL) }
        }
        RunLoop.main.add(killer, forMode: .common)
    }

    func openLiveView() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:8737")!)
    }

    /// Open a fresh Claude Cowork session with the `/live-recorder` skill
    /// invocation prefilled (deep link prefills; the user presses Enter — the
    /// scheme intentionally doesn't auto-send). The skill auto-picks the newest
    /// transcript = the active recording.
    func askClaudeAboutCall() {
        Task { @MainActor in
            // Lead with the meeting name so Cowork's session title isn't just
            // "Live recorder" for every call. Use the live recording's name;
            // otherwise best-effort calendar lookup.
            var name = isRecording ? meetingName : ""
            if name.isEmpty {
                name = await currentMeetingName()
            }
            // Lead with the slash command; append the name as its argument so the
            // Cowork session title reflects the meeting.
            let prompt = name.isEmpty ? "/live-recorder" : "/live-recorder \(name)"
            // Route verified against Claude.app's deep-link handler: cowork/new?q=
            // maps to /task/new?q= (q capped at 1024 chars, URLSearchParams-decoded,
            // so raw "/" and %2F are equivalent). Prefill is flaky when the app is
            // already running (warm path dispatches a navigate event instead of a
            // fresh load) — the clipboard copy below covers that: the user just ⌘V.
            //
            // Deliberately NO folder= param: any folder/file arg makes the handler
            // set src=external, which fires the "Another app attached" dialog — and
            // clicking Continue re-inits the draft session, wiping the prefilled q.
            // The skill attaches the recordings folder itself on first pull instead.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            let q = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "claude://cowork/new?q=\(q)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func openTranscriptsFolder() {
        try? FileManager.default.createDirectory(
            at: recordingsDir, withIntermediateDirectories: true)
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

    /// Confirm/enter the meeting name. Prefilled with `suggestion` (the current
    /// calendar event, text selected) so Enter accepts it and typing replaces
    /// it. Returns nil if the user cancels.
    private func promptForName(suggestion: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Name this recording"
        alert.informativeText = suggestion.isEmpty
            ? "No calendar event found — what's this meeting?"
            : "From your calendar — Enter to accept, or type over it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "e.g. Acme discovery"
        field.stringValue = suggestion
        alert.accessoryView = field
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        // Enough on its own when runModal is hosted by the run loop (see
        // start()): the field takes the cursor with its text selected.
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
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
