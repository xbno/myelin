import AVFoundation
import Foundation
import Speech

/// One streaming SpeechAnalyzer session for a single audio source ("mic" or "system").
/// Feed it AVAudioPCMBuffers in any format; it converts to the analyzer's preferred
/// format, streams results, and writes finalized utterances to the TranscriptWriter.
final class SpeechChannel {
    let source: String
    private let writer: TranscriptWriter
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let inputSequence: AsyncStream<AnalyzerInput>
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?

    init(source: String, locale: Locale, writer: TranscriptWriter) {
        self.source = source
        self.writer = writer
        self.transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        (self.inputSequence, self.inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
    }

    /// Ensure the on-device model for this locale is installed (one-time download).
    static func ensureModel(locale: Locale) async throws {
        let probe = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            FileHandle.standardError.write(Data("downloading speech model for \(locale.identifier)…\n".utf8))
            try await request.downloadAndInstall()
        }
    }

    func start() async throws {
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard analyzerFormat != nil else {
            throw RecorderError("no compatible audio format for SpeechTranscriber (\(source))")
        }

        let src = source
        let writer = writer
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        var t0: Double?
                        var t1: Double?
                        let range = result.range
                        t0 = range.start.seconds.isFinite ? range.start.seconds : nil
                        t1 = range.end.seconds.isFinite ? range.end.seconds : nil
                        await writer.write(source: src, text: text, t0: t0, t1: t1)
                        Console.finalLine(source: src, text: text)
                    } else {
                        Console.volatileLine(source: src, text: text)
                    }
                }
            } catch {
                Console.error("\(src) results stream ended: \(error)")
            }
        }

        let analyzer = analyzer
        let sequence = inputSequence
        analyzerTask = Task {
            do {
                try await analyzer.start(inputSequence: sequence)
            } catch {
                Console.error("\(src) analyzer failed to start: \(error)")
            }
        }
    }

    /// Feed a captured buffer (any format); converts and yields to the analyzer.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let analyzerFormat else { return }
        if buffer.format == analyzerFormat {
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { return }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            Console.error("\(source) convert error: \(err?.localizedDescription ?? "?")")
            return
        }
        guard out.frameLength > 0 else { return }
        inputBuilder.yield(AnalyzerInput(buffer: out))
    }

    func finish() async {
        inputBuilder.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            Console.error("\(source) finalize: \(error)")
        }
        _ = await analyzerTask?.value
        resultsTask?.cancel()
    }
}

struct RecorderError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
