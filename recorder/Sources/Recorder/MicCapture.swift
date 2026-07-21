import AVFoundation
import Foundation

/// Microphone capture via AVAudioEngine. Buffers go to the "mic" SpeechChannel.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let channel: SpeechChannel
    private let aec: Bool

    init(channel: SpeechChannel, aec: Bool = true) {
        self.channel = channel
        self.aec = aec
    }

    func start() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            Console.status("requesting microphone access — approve the macOS prompt…")
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw RecorderError("microphone access denied")
            }
        case .denied, .restricted:
            throw RecorderError(
                "microphone access denied — System Settings > Privacy & Security > Microphone")
        default:
            break
        }
        let input = engine.inputNode
        // Built-in macOS acoustic echo cancellation: the Voice-Processing I/O
        // removes speaker output (the other party) from the mic, so a
        // headphones-free call doesn't echo their audio back onto our "me"
        // channel. Must be set before the format is read / engine starts.
        if aec {
            do {
                try input.setVoiceProcessingEnabled(true)
                Console.status("mic AEC on (voice-processing) — echo cancellation active")
            } catch {
                Console.status("mic AEC unavailable (\(error)) — continuing without; use headphones")
            }
        }
        let nodeFormat = input.outputFormat(forBus: 0)
        guard nodeFormat.sampleRate > 0 else {
            throw RecorderError("no microphone input available")
        }
        // Default path: tap the node's own format (proven working). AEC path:
        // voice-processing makes the node multi-channel and a manual
        // AVAudioConverter (SpeechChannel's) yields SILENCE on those buffers, so
        // install a MONO tap and let AVAudioEngine's own conversion downmix
        // correctly (Apple forums 771530).
        let tapFormat: AVAudioFormat =
            aec
            ? (AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: nodeFormat.sampleRate,
                channels: 1, interleaved: false) ?? nodeFormat)
            : nodeFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [channel] buffer, _ in
            channel.feed(buffer)
        }
        engine.prepare()
        try engine.start()
        Console.status(
            "mic capture started (\(Int(tapFormat.sampleRate)) Hz, \(tapFormat.channelCount) ch"
                + (aec ? ", AEC" : "") + ")")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
