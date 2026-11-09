import AVFAudio
import AudioToolbox

@MainActor final class Microphone {
    static let preference = "Microphone"

    let ring = Ring()
    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?

    func start() {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = UserDefaults.standard.string(forKey: Self.preference),
           let device = AudioDevices.inputs().first(where: { $0.uid == uid }),
           let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.error("microphone: cannot select \(device.name): \(status)") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let resampler = Resampler(from: format) else {
            Log.error("microphone: no input device")
            return
        }
        let sink = Self.sink(format: format, resampler: resampler, ring: ring)
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
        do {
            try engine.start()
        } catch {
            Log.error("microphone: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        Log.debug("microphone: \(Int(format.sampleRate)) Hz, \(format.channelCount) channels")
    }

    private func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine = nil
    }

    nonisolated private static func sink(format: AVAudioFormat, resampler: Resampler, ring: Ring) -> AVAudioSinkNode {
        AVAudioSinkNode { _, _, list in
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) {
                resampler.convert(buffer, last: false, ring.append)
            }
            return noErr
        }
    }
}
