import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// System-audio capture via a Core Audio process tap (macOS 14.2+).
/// Global tap (all processes) wrapped in a private aggregate device; buffers go
/// to the "system" SpeechChannel. First run triggers the system-audio TCC prompt.
///
/// The tap's stream format is fixed at creation, but macOS changes it whenever
/// the default output route changes (AirPods drop to speakers, sample-rate
/// switch, auto-switch to phone). After that the stale-format buffer wrap
/// returns nil on every callback and capture silently starves — a listen-only
/// call then freezes with no visible error (July 27 acme stall). So the tap
/// self-heals: it watches its own IO health and the default output device and
/// rebuilds itself when either degrades.
final class SystemAudioTap {
    private let channel: SpeechChannel
    private let diarizer: SystemDiarizer?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "system-tap-io")

    // Health state. Only touched on `queue` (IOProc, health timer and device
    // listener all run there), so no locking is needed.
    private var lastIO = Date.distantPast  // last usable buffer from the IOProc
    private var wrapFailures = 0  // consecutive nil buffer wraps (stale format)
    private var lastRebuild = Date.distantPast
    private var stopped = false
    private var healthTimer: DispatchSourceTimer?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    private static var defaultOutputAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init(channel: SpeechChannel, diarizer: SystemDiarizer? = nil) {
        self.channel = channel
        self.diarizer = diarizer
    }

    func start() throws {
        try queue.sync {
            try startCore_onQueue()
            lastIO = Date()
        }

        // Rebuild proactively when the default output device changes — the
        // primary real-world trigger for a tap format change.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuild_onQueue(reason: "default output device changed")
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddr, queue, listener)
        deviceListener = listener

        // Fallback watchdog for anything the listener misses: failed wraps
        // (format changed under us) or the device going quiet entirely.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.healthCheck_onQueue() }
        timer.resume()
        healthTimer = timer
    }

    private func startCore_onQueue() throws {
        // 1. Global tap: capture every process's output, post-mix.
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard status == noErr else {
            throw RecorderError("AudioHardwareCreateProcessTap failed (\(status)) — check System Settings > Privacy & Security > Screen & System Audio Recording")
        }
        self.tapID = tapID

        // 2. Read the tap's stream format (valid until the output route changes;
        // the health machinery rebuilds us when that happens).
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError("could not read tap format (\(status))")
        }

        // 3. Private aggregate device containing just the tap.
        let uid = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "live-recorder tap",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else {
            throw RecorderError("AudioHardwareCreateAggregateDevice failed (\(status))")
        }
        self.aggregateID = aggregateID

        // 4. IOProc: deliver captured buffers to the speech channel + diarizer.
        let channel = self.channel
        let diarizer = self.diarizer
        let fmt = format
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            let ablPointer = UnsafeMutablePointer(mutating: inInputData)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: ablPointer, deallocator: nil),
                  buffer.frameLength > 0
            else {
                // Stale format wraps fail on every callback; the health timer
                // sees the streak and rebuilds the tap.
                self?.wrapFailures += 1
                return
            }
            self?.wrapFailures = 0
            self?.lastIO = Date()
            channel.feed(buffer)
            diarizer?.feed(buffer)
        }
        guard status == noErr else {
            throw RecorderError("AudioDeviceCreateIOProcIDWithBlock failed (\(status))")
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            throw RecorderError("AudioDeviceStart failed (\(status))")
        }
        Console.status("system-audio tap started (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)")
    }

    private func healthCheck_onQueue() {
        guard !stopped else { return }
        if aggregateID == kAudioObjectUnknown {
            rebuild_onQueue(reason: "previous rebuild failed")  // retry
        } else if wrapFailures >= 3 {
            rebuild_onQueue(reason: "buffer format changed (\(wrapFailures) failed wraps)")
        } else if Date().timeIntervalSince(lastIO) > 60 {
            rebuild_onQueue(reason: "no audio for 60s — device may have stopped")
        }
    }

    private func rebuild_onQueue(reason: String) {
        guard !stopped, Date().timeIntervalSince(lastRebuild) > 3 else { return }
        lastRebuild = Date()
        Console.status("system tap rebuilding — \(reason)")
        stopCore_onQueue()
        do {
            try startCore_onQueue()
            Console.status("system tap rebuilt")
        } catch {
            Console.error("system tap rebuild failed (will retry): \(error)")
        }
        wrapFailures = 0
        lastIO = Date()  // grace period before the watchdog fires again
    }

    private func stopCore_onQueue() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    func stop() {
        if let deviceListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddr, queue,
                deviceListener)
            self.deviceListener = nil
        }
        queue.sync {
            stopped = true
            healthTimer?.cancel()
            healthTimer = nil
            stopCore_onQueue()
        }
    }
}
