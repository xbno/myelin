import AVFoundation
import FluidAudio
import Foundation

/// Streaming speaker diarization for the system-audio channel (FluidAudio
/// LS-EEND, CoreML, fully local). Tap buffers are downmixed to mono Float and
/// processed on a serial queue; the resulting speaker timeline is queried when
/// transcript lines are written, labeling them S1/S2/… or enrolled names.
///
/// Voice enrollment: any audio files in the speakers dir (default
/// `<recordings-dir>/speakers/`) are enrolled at startup, one speaker per
/// file, named after the file (e.g. `Alice.wav` → lines from that voice are
/// labeled "Alice"). Voices named live by platform hints (meet-tap) are saved
/// back to that dir at session end, so a speaker named once on any platform
/// stays identified in every later call.
final class SystemDiarizer {
    private let diarizer = LSEENDDiarizer()
    private let queue = DispatchQueue(label: "diarizer", qos: .userInitiated)
    private let store = SegmentStore()
    private var started = false
    /// Seconds of audio handed to the model so far (accessed on `queue`).
    private var processedSeconds: Double = 0
    private let voiceBank = VoiceBank()
    private var saveDir: URL?

    func start(enrollDir: URL?) async throws {
        Console.status("loading diarization model (first run downloads it)…")
        try await diarizer.initialize(variant: .dihard3, stepSize: .step100ms)

        if let enrollDir {
            saveDir = enrollDir
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
            voiceBank.markKnown(name)  // already on disk; no need to re-save
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
            voiceBank.append(mono, rate: rate)
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
            if let saveDir {
                voiceBank.save(to: saveDir)
            }
        }
    }

    /// Adopt an externally-hinted name (e.g. from meet-tap) for whichever
    /// voice slot dominated [t0, t1]: the voice model learns the name live,
    /// so it keeps working when hints stop. First hint wins; never renames.
    func adoptName(_ name: String, t0: Double, t1: Double) {
        guard started else { return }
        // The hint certifies "[t0, t1] is `name`" regardless of slot mapping —
        // bank that audio so the voice can be enrolled in future sessions.
        queue.async { [self] in
            voiceBank.harvest(name: name, t0: t0, t1: t1)
        }
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

/// Banks audio clips for speakers named live by platform hints and saves them
/// as enrollment samples (`<speakers-dir>/<Name>.wav`) at session end, so a
/// voice named once (e.g. by Meet captions) is recognized by voice alone in
/// every later call, on any platform. All methods run on the diarizer queue.
final class VoiceBank {
    private let ringSeconds = 60.0  // how far back a hint can reach
    private let clipTargetSeconds = 20.0  // per-name enrollment audio cap
    private let clipMinSeconds = 3.0  // don't save less than this
    private let utteranceMinSeconds = 1.5  // ignore blips too short to help

    private var ring: [Float] = []
    private var totalWritten = 0  // samples ever appended; ring holds the tail
    private var rate: Double = 0
    private var clips: [String: [Float]] = [:]
    private var known: Set<String> = []  // names already on disk

    func markKnown(_ name: String) {
        known.insert(name)
    }

    func append(_ mono: [Float], rate: Double) {
        if self.rate != rate {  // first buffer (or a device switch: start over)
            self.rate = rate
            ring = [Float](repeating: 0, count: Int(ringSeconds * rate))
            totalWritten = 0
        }
        for sample in mono {
            ring[totalWritten % ring.count] = sample
            totalWritten += 1
        }
    }

    /// Copy the ring audio under a hinted utterance into that name's clip.
    func harvest(name: String, t0: Double, t1: Double) {
        guard rate > 0, !known.contains(name) else { return }
        let existing = clips[name] ?? []
        guard Double(existing.count) / rate < clipTargetSeconds else { return }

        let oldest = max(0, totalWritten - ring.count)
        let s0 = max(Int(t0 * rate), oldest)
        let s1 = min(Int(t1 * rate), totalWritten)
        guard Double(s1 - s0) / rate >= utteranceMinSeconds else { return }

        var clip = existing
        clip.reserveCapacity(clip.count + (s1 - s0))
        for i in s0..<s1 {
            clip.append(ring[i % ring.count])
        }
        clips[name] = clip
    }

    /// Write banked clips as `<Name>.wav` enrollment samples (never overwrites).
    func save(to dir: URL) {
        guard rate > 0 else { return }
        let ready = clips.filter { Double($0.value.count) / rate >= clipMinSeconds }
        guard !ready.isEmpty else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, samples) in ready.sorted(by: { $0.key < $1.key }) {
            let safe = String(name.map { "/\\:\0".contains($0) ? "-" : $0 })
            let url = dir.appendingPathComponent("\(safe).wav")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            guard
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1,
                    interleaved: false),
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
            else { continue }
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
                Console.status(String(format: "saved voice sample \"%@\" (%.1fs) → %@",
                                      name, Double(samples.count) / rate, url.path))
            } catch {
                Console.error("could not save voice sample for \(name): \(error)")
            }
        }
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
