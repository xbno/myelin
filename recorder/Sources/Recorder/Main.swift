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
            case "--help", "-h":
                print("""
                usage: recorder [--out FILE.jsonl] [--locale en-US] [--mic-only|--system-only]

                Records mic + system audio and transcribes both locally (SpeechAnalyzer,
                on-device) into an append-only JSONL transcript. Ctrl-C to stop.
                Default output: ~/Library/Application Support/live-recorder/transcripts/<timestamp>.jsonl
                """)
                return
            default:
                FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
                exit(2)
            }
        }

        let sessionStart = Date()
        let stamp = ISO8601DateFormatter().string(from: sessionStart)
            .replacingOccurrences(of: ":", with: "-")
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/live-recorder/transcripts")
        let outPath = out ?? defaultDir.appendingPathComponent("\(stamp).jsonl").path
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

        do {
            if !systemOnly {
                let micChannel = SpeechChannel(source: "mic", locale: locale, writer: writer)
                try await micChannel.start()
                mic = MicCapture(channel: micChannel)
                try mic!.start()
                channels.append(micChannel)
            }
            if !micOnly {
                let sysChannel = SpeechChannel(source: "system", locale: locale, writer: writer)
                try await sysChannel.start()
                tap = SystemAudioTap(channel: sysChannel)
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

        for await _ in stopped.stream { break }

        Console.status("stopping — finalizing transcription…")
        mic?.stop()
        tap?.stop()
        for channel in channels {
            await channel.finish()
        }
        let n = await writer.count
        await writer.close()
        Console.status("done: \(n) lines → \(outPath)")
    }
}
