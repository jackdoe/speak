import AVFoundation
import Accelerate

@Observable
class AudioEngine {

    var isRecording: Bool = false
    var audioLevel: Float = 0.0

    private let engine = AVAudioEngine()
    private let vad = VoiceActivityDetector()
    private var isEngineRunning = false
    private var isCollecting = false

    let rawBuffer = RingBuffer()
    private(set) var hardwareSampleRate: Double = 48000

    func prepare() throws {
        guard !isEngineRunning else { return }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioEngineError.noInputDevice
        }

        hardwareSampleRate = hwFormat.sampleRate
        NSLog("[AudioEngine] Hardware format: %.0f Hz, %d ch", hwFormat.sampleRate, hwFormat.channelCount)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) {
            [weak self] (pcmBuffer, _) in
            self?.handleAudioBuffer(pcmBuffer)
        }

        engine.prepare()
        try engine.start()
        isEngineRunning = true
        NSLog("[AudioEngine] Engine started (always-on)")
    }

    func startRecording() throws {
        if !isEngineRunning {
            try prepare()
        }
        vad.reset()
        _ = rawBuffer.drain()
        isCollecting = true
        isRecording = true
    }

    func stopRecording() -> [Float] {
        isCollecting = false
        isRecording = false

        let rawSamples = rawBuffer.drain()
        vad.reset()

        NSLog("[AudioEngine] Stopped. Raw samples: %d (%.1fs at %.0f Hz)",
              rawSamples.count, Double(rawSamples.count) / hardwareSampleRate, hardwareSampleRate)

        guard !rawSamples.isEmpty else { return [] }

        let resampled = resample(rawSamples, from: hardwareSampleRate, to: 16000)
        NSLog("[AudioEngine] Resampled to %d samples (%.1fs at 16kHz)", resampled.count, Double(resampled.count) / 16000.0)
        return resampled
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    var voiceActivityDetector: VoiceActivityDetector { vad }

    func releaseEngine() {
        guard isEngineRunning else { return }
        isCollecting = false
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isEngineRunning = false
        NSLog("[AudioEngine] Engine stopped, mic released")
    }

    private func handleAudioBuffer(_ pcmBuffer: AVAudioPCMBuffer) {
        guard let channelData = pcmBuffer.floatChannelData else { return }
        let frameCount = Int(pcmBuffer.frameLength)
        guard frameCount > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let rms = min(1.0, sqrtf(sumSq / Float(frameCount)))
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = rms
        }

        guard isCollecting else { return }

        let filtered = vad.process(samples: samples, sampleRate: Int(hardwareSampleRate))
        if !filtered.isEmpty {
            rawBuffer.append(filtered)
        }
    }

    func resamplePublic(_ input: [Float]) -> [Float] {
        resample(input, from: hardwareSampleRate, to: 16000)
    }

    private func resample(_ input: [Float], from sourceSR: Double, to targetSR: Double) -> [Float] {
        guard sourceSR != targetSR, !input.isEmpty else { return input }

        let ratio = sourceSR / targetSR
        let outputCount = Int(Double(input.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIdx = Double(i) * ratio
            let idx0 = Int(srcIdx)
            let frac = Float(srcIdx - Double(idx0))
            let idx1 = min(idx0 + 1, input.count - 1)
            output[i] = input[idx0] * (1.0 - frac) + input[idx1] * frac
        }
        return output
    }
}

enum AudioEngineError: Error, LocalizedError {
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device available"
        }
    }
}
