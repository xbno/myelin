import AVFoundation
import FluidAudio
import Foundation

/// Streaming speaker diarization for the system-audio channel (FluidAudio
/// LS-EEND, CoreML, fully local). Tap buffers are downmixed to mono Float and
/// processed on a serial queue; the resulting speaker timeline is queried when
/// transcript lines are written, labeling them S1/S2/… or enrolled names.
///
/// Voice enrollment: any audio files in
/// `~/Library/Application Support/live-recorder/speakers/` are enrolled at
/// startup, one speaker per file, named after the file (e.g. `Alice.wav` →
/// lines from that voice are labeled "Alice").
final class SystemDiarizer {
    private let diarizer = LSEENDDiarizer()
    private let queue = DispatchQueue(label: "diarizer", qos: .userInitiated)
    private let store = SegmentStore()
    private var started = false

    func start(enrollDir: URL?) async throws {
        Console.status("loading diarization model (first run downloads it)…")
        try await diarizer.initialize(variant: .dihard3, stepSize: .step100ms)

        if let enrollDir {
            enroll(from: enrollDir)
        }
        started = true
        Console.status("diarization ready (\(diarizer.numSpeakers ?? 0) speaker slots)")
    }

    private func enroll(from dir: URL) {
        let audioExts = ["wav", "m4a", "mp3", "aiff", "caf", "flac"]
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else { return }
        let samples = files
            .filter { audioExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in samples {
            let name = file.deletingPathExtension().lastPathComponent
            guard let (audio, rate) = Self.loadAudio(file) else {
                Console.error("enroll: could not read \(file.lastPathComponent)")
                continue
            }
            do {
                if let speaker = try diarizer.enrollSpeaker(
                    withAudio: audio, sourceSampleRate: rate, named: name)
                {
                    Console.status("enrolled speaker \"\(speaker.name ?? name)\"")
                } else {
                    Console.error("enroll: no clear voice found in \(file.lastPathComponent)")
                }
            } catch {
                Console.error("enroll \(file.lastPathComponent): \(error)")
            }
        }
    }

    /// Called from the audio IO callback — must not block.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard started else { return }
        let mono = Self.downmix(buffer)
        guard !mono.isEmpty else { return }
        let rate = buffer.format.sampleRate
        queue.async { [self] in
            do {
                try diarizer.addAudio(mono, sourceSampleRate: rate)
                if (try diarizer.process()) != nil {
                    store.replace(with: diarizer.timeline)
                }
            } catch {
                Console.error("diarizer: \(error)")
            }
        }
    }

    /// Best speaker label for an utterance spanning [t0, t1] seconds of the
    /// system-audio stream, or nil if diarization has no confident overlap.
    func label(t0: Double, t1: Double) -> String? {
        store.dominantSpeaker(t0: t0, t1: t1)
    }

    func finish() {
        queue.sync {
            _ = try? diarizer.finalizeSession()
            store.replace(with: diarizer.timeline)
            for (index, speaker) in diarizer.timeline.speakers.sorted(by: { $0.key < $1.key }) {
                guard speaker.hasSegments else { continue }
                let name = speaker.name ?? "S\(index + 1)"
                Console.status(String(format: "speaker %@: %.1fs speech in %d segments",
                                      name, speaker.speechDuration, speaker.segmentCount))
            }
        }
    }

    /// Debug: offline-diarize an audio file and print the speaker timeline.
    static func debugDiarizeFile(path: String) async {
        do {
            let diarizer = LSEENDDiarizer()
            try await diarizer.initialize(variant: .dihard3, stepSize: .step100ms)
            let timeline = try diarizer.processComplete(
                audioFileURL: URL(fileURLWithPath: path))
            for (index, speaker) in timeline.speakers.sorted(by: { $0.key < $1.key }) {
                guard speaker.hasSegments else { continue }
                let name = speaker.name ?? "S\(index + 1)"
                print(String(format: "%@: %.1fs in %d segments", name,
                             speaker.speechDuration, speaker.segmentCount))
                for seg in speaker.finalizedSegments {
                    print(String(format: "  %6.1f – %6.1f  (activity %.2f)",
                                 seg.startTime, seg.endTime, seg.activity))
                }
            }
        } catch {
            Console.error("diarize-file: \(error)")
        }
    }

    // MARK: - Audio helpers

    static func downmix(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frames))
        }
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1.0 / Float(channels)
        if buffer.format.isInterleaved {
            // Interleaved: only data[0] is valid, samples are frame-major.
            let src = data[0]
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += src[i * channels + ch] }
                mono[i] = sum * scale
            }
        } else {
            for ch in 0..<channels {
                let src = data[ch]
                for i in 0..<frames { mono[i] += src[i] }
            }
            for i in 0..<frames { mono[i] *= scale }
        }
        return mono
    }

    static func loadAudio(_ url: URL) -> ([Float], Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
            (try? file.read(into: buffer)) != nil
        else { return nil }
        return (downmix(buffer), format.sampleRate)
    }
}

/// Thread-safe snapshot of the diarizer's speaker timeline.
final class SegmentStore {
    private struct Entry {
        let speakerIndex: Int
        let name: String?
        let start: Double
        let end: Double
        let finalized: Bool
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func replace(with timeline: DiarizerTimeline) {
        var new: [Entry] = []
        for (index, speaker) in timeline.speakers {
            for segment in speaker.finalizedSegments {
                new.append(
                    Entry(
                        speakerIndex: index, name: speaker.name,
                        start: Double(segment.startTime), end: Double(segment.endTime),
                        finalized: true))
            }
            for segment in speaker.tentativeSegments {
                new.append(
                    Entry(
                        speakerIndex: index, name: speaker.name,
                        start: Double(segment.startTime), end: Double(segment.endTime),
                        finalized: false))
            }
        }
        lock.lock()
        entries = new
        lock.unlock()
    }

    func dominantSpeaker(t0: Double, t1: Double) -> String? {
        guard t1 > t0 else { return nil }
        lock.lock()
        let snapshot = entries
        lock.unlock()

        var overlapBySpeaker: [Int: (duration: Double, name: String?)] = [:]
        for entry in snapshot {
            let overlap = min(entry.end, t1) - max(entry.start, t0)
            guard overlap > 0 else { continue }
            var acc = overlapBySpeaker[entry.speakerIndex] ?? (0, entry.name)
            acc.duration += overlap
            if acc.name == nil { acc.name = entry.name }
            overlapBySpeaker[entry.speakerIndex] = acc
        }
        guard let best = overlapBySpeaker.max(by: { $0.value.duration < $1.value.duration }),
            best.value.duration >= 0.2 * (t1 - t0)
        else { return nil }
        return best.value.name ?? "S\(best.key + 1)"
    }
}
