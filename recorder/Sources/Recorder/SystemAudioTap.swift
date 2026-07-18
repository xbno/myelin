import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// System-audio capture via a Core Audio process tap (macOS 14.2+).
/// Global tap (all processes) wrapped in a private aggregate device; buffers go
/// to the "system" SpeechChannel. First run triggers the system-audio TCC prompt.
final class SystemAudioTap {
    private let channel: SpeechChannel
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "system-tap-io")

    init(channel: SpeechChannel) {
        self.channel = channel
    }

    func start() throws {
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

        // 2. Read the tap's stream format.
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
        self.tapFormat = format

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

        // 4. IOProc: deliver captured buffers to the speech channel.
        let channel = self.channel
        let fmt = format
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            _, inInputData, _, _, _ in
            let ablPointer = UnsafeMutablePointer(mutating: inInputData)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: ablPointer, deallocator: nil),
                  buffer.frameLength > 0
            else { return }
            channel.feed(buffer)
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

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }
}
