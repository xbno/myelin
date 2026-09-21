import AVFoundation
import Foundation
import Speech

@main
struct Main {
    static func main() async {
        var out: String?
        var localeID = "en-US"
        var micOnly = false
        var systemOnly = false
        var diarize = true
        var aec = false  // opt-in via --aec: macOS voice-processing echo
        // cancellation. Default off so the proven mic path stays untouched
        // until AEC is confirmed working on a real speakers-on call.
        var diarizeFile: String?
        var meetPort: UInt16 = 8737  // --meet-port 0 disables
        var fast = false

        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--out", "-o":
                out = args.isEmpty ? nil : args.removeFirst()
            case "--locale":
                localeID = args.isEmpty ? localeID : args.removeFirst()
            case "--mic-only":
                micOnly = true
            case "--system-only":
                systemOnly = true
            case "--aec":
                aec = true
            case "--no-diarize":
                diarize = false
            case "--diarize-file":
                diarizeFile = args.isEmpty ? nil : args.removeFirst()
            case "--meet-port":
                meetPort = args.isEmpty ? meetPort : UInt16(args.removeFirst()) ?? meetPort
            case "--fast":
                fast = true  // quicker finalization, possibly lower accuracy (A/B it)
            case "--ax-dump", "--ax-watch":
                let app = (args.first == "--app") ? (args.dropFirst().first) : nil
                AXProbe.run(watch: arg == "--ax-watch", bundleID: app)
                return
            case "--help", "-h":
                print("""
                usage: recorder [--out FILE.jsonl] [--locale en-US] [--mic-only|--system-only]
                                [--no-diarize] [--aec] [--meet-port N] [--fast]

                Records mic + system audio and transcribes both locally (SpeechAnalyzer,
                on-device) into an append-only JSONL transcript. Ctrl-C to stop.
                Output folder: $LIVE_RECORDER_DIR, else whatever the menu-bar app
                saved in ~/.config/live-recorder/recordings-dir, else ~/recordings.
                Override one run with --out. Missing folders are created.

                Speaker labels: remote speakers are diarized locally (FluidAudio LS-EEND)
                into S1/S2/…, for one call only. Real names come from a live meet-tap
                hint; no voiceprint is kept between sessions.
                """)
                return
            default:
                FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
                exit(2)
            }
        }

        if let diarizeFile {
            await SystemDiarizer.debugDiarizeFile(path: diarizeFile)
            return
        }

        let sessionStart = Date()
        let stamp = ISO8601DateFormatter().string(from: sessionStart)
            .replacingOccurrences(of: ":", with: "-")
        // Not ~/Library: a macOS-protected path that sandboxed agents like
        // Cowork can't mount. The folder is the user's own, picked once in the
        // menu-bar app and saved as one line of text that this CLI and the
        // pull skill both read — so no checkout path is baked in anywhere.
        let baseDir: URL = {
            if let env = ProcessInfo.processInfo.environment["LIVE_RECORDER_DIR"], !env.isEmpty {
                return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
            }
            let config = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/live-recorder/recordings-dir")
            if let text = try? String(contentsOf: config, encoding: .utf8) {
                let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                }
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("recordings")
        }()
        let outPath = out ?? baseDir.appendingPathComponent("\(stamp).jsonl").path
        let locale = Locale(identifier: localeID)

        do {
            try await SpeechChannel.ensureModel(locale: locale)
        } catch {
            Console.error("speech model unavailable for \(localeID): \(error)")
            exit(1)
        }

        let writer: TranscriptWriter
        do {
            writer = try TranscriptWriter(path: outPath)
        } catch {
            Console.error("cannot open \(outPath): \(error)")
            exit(1)
        }

        var channels: [SpeechChannel] = []
        var mic: MicCapture?
        var tap: SystemAudioTap?
        var diarizer: SystemDiarizer?
        let partialStore = PartialStore()

        do {
            if !systemOnly {
                let micChannel = SpeechChannel(
                    source: "mic", locale: locale, writer: writer, fast: fast)
                micChannel.partials = partialStore
                try await micChannel.start()
                mic = MicCapture(channel: micChannel, aec: aec)
                try await mic!.start()
                channels.append(micChannel)
            }
            if !micOnly {
                if diarize {
                    let d = SystemDiarizer()
                    do {
                        try await d.start()
                        diarizer = d
                    } catch {
                        Console.error("diarization unavailable, continuing without: \(error)")
                    }
                }
                var hints: MeetHints?
                if meetPort != 0 {
                    let h = MeetHints()
                    h.transcriptPath = outPath
                    h.partials = partialStore
                    do {
                        try h.start(port: meetPort)
                        hints = h
                    } catch {
                        Console.error("meet-tap listener unavailable: \(error)")
                    }
                }

                let sysChannel = SpeechChannel(
                    source: "system", locale: locale, writer: writer, fast: fast)
                sysChannel.partials = partialStore
                let sysEpoch = Date()  // stream time t=0 ≈ tap start (set just below)
                let d = diarizer
                sysChannel.labeler = { t0, t1 in
                    if let hints,
                        let name = hints.query(
                            w0: sysEpoch.addingTimeInterval(t0),
                            w1: sysEpoch.addingTimeInterval(t1))
                    {
                        d?.adoptName(name, t0: t0, t1: t1)
                        return name
                    }
                    return await d?.labelWaiting(t0: t0, t1: t1)
                }
                try await sysChannel.start()
                tap = SystemAudioTap(channel: sysChannel, diarizer: diarizer)
                try tap!.start()
                channels.append(sysChannel)
            }
        } catch {
            Console.error("\(error)")
            exit(1)
        }

        Console.status("recording → \(outPath)  (Ctrl-C to stop)")

        // Graceful shutdown on SIGINT/SIGTERM.
        let stopped = AsyncStream<Void>.makeStream()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        for source in [sigint, sigterm] {
            source.setEventHandler { stopped.continuation.yield() }
            source.resume()
        }

        // Also stop when the parent (menubar app or shell) dies — otherwise
        // killing the parent orphans us and the mic stays live with nothing
        // left that can stop it.
        let ppid = getppid()
        let parentExit = DispatchSource.makeProcessSource(
            identifier: ppid, eventMask: .exit, queue: .main)
        parentExit.setEventHandler { stopped.continuation.yield() }
        parentExit.resume()
        if ppid <= 1 || kill(ppid, 0) != 0 {  // parent already gone (raced our launch)
            stopped.continuation.yield()
        }

        for await _ in stopped.stream { break }

        Console.status("stopping — finalizing transcription…")
        mic?.stop()
        tap?.stop()
        diarizer?.finish()
        for channel in channels {
            await channel.finish()
        }
        let n = await writer.count
        await writer.close()
        Console.status("done: \(n) lines → \(outPath)")
    }
}
