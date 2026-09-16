import AVFoundation
import Foundation

/// Microphone capture via AVAudioEngine. Buffers go to the "mic" SpeechChannel.
///
/// AVAudioEngine stops itself when the input route/format changes (AirPods
/// connect or drop, etc.) and never restarts on its own — the same silent-starve
/// failure mode as the system tap. Restart on the configuration-change
/// notification, but only when the input format actually changed — the same
/// notification fires for output-only route changes.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let channel: SpeechChannel
    private let aec: Bool
    private var configObserver: (any NSObjectProtocol)?
    private var stopped = false
    /// Format of the tap currently installed, to tell a real input change from
    /// an output-only one (see `restartEngine`).
    private var installedFormat: AVAudioFormat?

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
        try startEngine()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Let the route settle — the notification can arrive mid-transition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.restartEngine()
            }
        }
    }

    private func startEngine() throws {
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
        // Default path: pass nil and let AVAudioEngine read the bus format
        // itself. Handing it a format read a moment earlier races the route
        // change — installTap then throws an ObjC NSException, which Swift
        // cannot catch, so it kills the whole recording instead of just the mic.
        // AEC path: voice-processing makes the node multi-channel and a manual
        // AVAudioConverter (SpeechChannel's) yields SILENCE on those buffers, so
        // install a MONO tap and let AVAudioEngine's own conversion downmix
        // correctly (Apple forums 771530).
        let requested: AVAudioFormat? =
            aec
            ? AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: nodeFormat.sampleRate,
                channels: 1, interleaved: false)
            : nil
        input.installTap(onBus: 0, bufferSize: 4096, format: requested) { [channel] buffer, _ in
            channel.feed(buffer)
        }
        engine.prepare()
        try engine.start()
        let live = requested ?? nodeFormat
        installedFormat = live
        Console.status(
            "mic capture started (\(Int(live.sampleRate)) Hz, \(live.channelCount) ch"
                + (aec ? ", AEC" : "") + ")")
    }

    private func restartEngine() {
        guard !stopped else { return }
        // The notification also fires for OUTPUT route changes — headphones,
        // a monitor's speakers — which leave the microphone untouched. Tearing
        // the tap down then is pure risk for no gain, and it is what killed the
        // Sep 16 call: the default output device changed, the mic engine
        // restarted anyway, and installTap threw mid-transition.
        let current = engine.inputNode.outputFormat(forBus: 0)
        if engine.isRunning, let installedFormat,
            installedFormat.sampleRate == current.sampleRate,
            installedFormat.channelCount == current.channelCount
        {
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try startEngine()
            Console.status("mic restarted after audio route change")
        } catch {
            Console.error("mic restart failed after route change: \(error)")
        }
    }

    func stop() {
        stopped = true
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
