import AVFoundation
import Foundation

/// Microphone capture via AVAudioEngine. Buffers go to the "mic" SpeechChannel.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let channel: SpeechChannel

    init(channel: SpeechChannel) {
        self.channel = channel
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw RecorderError("no microphone input available")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [channel] buffer, _ in
            channel.feed(buffer)
        }
        engine.prepare()
        try engine.start()
        Console.status("mic capture started (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
