import AVFoundation
import FluidAudio
import Foundation

/// Streaming speaker diarization for the system-audio channel (FluidAudio
/// LS-EEND, CoreML, fully local). Tap buffers are downmixed to mono Float and
/// processed on a serial queue; the resulting speaker timeline is queried when
/// transcript lines are written, labeling them S1/S2/….
///
/// Labels are per-session only. Names come from live platform hints (meet-tap)
/// and apply to the call that produced them. Nothing about a voice is carried
/// over to a later session: a name true in one meeting is not evidence about
/// who is speaking in the next one.
final class SystemDiarizer {
    private let diarizer = LSEENDDiarizer()
    private let queue = DispatchQueue(label: "diarizer", qos: .userInitiated)
    private let store = SegmentStore()
    private var started = false
    /// Seconds of audio handed to the model so far (accessed on `queue`).
    private var processedSeconds: Double = 0

    func start() async throws {
        Console.status("loading diarization model (first run downloads it)…")
        try await diarizer.initialize(variant: .dihard3, stepSize: .step100ms)
        started = true
        Console.status("diarization ready (\(diarizer.numSpeakers ?? 0) speaker slots)")
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
                processedSeconds += Double(mono.count) / rate
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

    /// Like `label(t0:t1:)`, but waits (bounded) for the diarizer to catch up
    /// first. ASR finalizes an utterance right at the live edge of the audio,
    /// before this model's lagging queue has labeled that stretch — querying
    /// immediately returned nil and the line was written without a speaker.
    func labelWaiting(t0: Double, t1: Double) async -> String? {
        let start = ContinuousClock.now
        let catchUpDeadline = start + .seconds(5)
        while ContinuousClock.now < catchUpDeadline, queue.sync(execute: { processedSeconds }) < t1 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Emitted segments trail the processed frontier by the model's
        // lookahead, so keep polling briefly after coverage is reached.
        let graceDeadline = ContinuousClock.now + .seconds(1)
        var speaker: String?
        while true {
            speaker = label(t0: t0, t1: t1)
            if speaker != nil { break }
            if ContinuousClock.now >= graceDeadline { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        let waited = start.duration(to: .now)
        if waited > .milliseconds(500) {
            let secs = Double(waited.components.seconds)
                + Double(waited.components.attoseconds) / 1e18
            Console.status(String(format: "diarizer wait %.1fs for [%.1f–%.1f] → %@",
                                  secs, t0, t1, speaker ?? "no speaker"))
        }
        return speaker
    }

    func finish() {
        queue.sync {
            processedSeconds = .infinity
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

    /// Adopt an externally-hinted name (e.g. from meet-tap) for whichever
    /// voice slot dominated [t0, t1], so the name sticks to that voice for the
    /// rest of this call when hints stop. First hint wins; never renames.
    func adoptName(_ name: String, t0: Double, t1: Double) {
        guard started else { return }
        guard let slot = store.dominantSlot(t0: t0, t1: t1) else { return }
        queue.async { [self] in
            guard let speaker = diarizer.timeline.speakers[slot], speaker.name == nil,
                !diarizer.timeline.speakers.values.contains(where: { $0.name == name })
            else { return }
            if diarizer.timeline.upsertSpeaker(named: name, atIndex: slot) != nil {
                store.replace(with: diarizer.timeline)
                Console.status("voice S\(slot + 1) identified as \"\(name)\" (meet-tap)")
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
        guard let best = dominant(t0: t0, t1: t1) else { return nil }
        return best.name ?? "S\(best.slot + 1)"
    }

    func dominantSlot(t0: Double, t1: Double) -> Int? {
        dominant(t0: t0, t1: t1)?.slot
    }

    private func dominant(t0: Double, t1: Double) -> (slot: Int, name: String?)? {
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
        return (best.key, best.value.name)
    }
}
