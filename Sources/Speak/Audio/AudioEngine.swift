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
    var inputGain: Float = 1.0

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

        var deviceName = "unknown"
        if let device = AVCaptureDevice.default(for: .audio) {
            deviceName = device.localizedName
        }
        NSLog("[AudioEngine] Input device: %@, format: %.0f Hz, %d ch", deviceName, hwFormat.sampleRate, hwFormat.channelCount)

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

        guard !rawSamples.isEmpty else {
            NSLog("[AudioEngine] Stopped. No samples captured")
            return []
        }

        var rawRMS: Float = 0
        var rawPeak: Float = 0
        vDSP_rmsqv(rawSamples, 1, &rawRMS, vDSP_Length(rawSamples.count))
        vDSP_maxmgv(rawSamples, 1, &rawPeak, vDSP_Length(rawSamples.count))
        NSLog("[AudioEngine] Stopped. %d samples (%.1fs at %.0f Hz) RMS=%.5f Peak=%.5f",
              rawSamples.count, Double(rawSamples.count) / hardwareSampleRate, hardwareSampleRate, rawRMS, rawPeak)

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

        var samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

        let gain = inputGain
        if gain != 1.0 {
            var g = gain
            vDSP_vsmul(samples, 1, &g, &samples, 1, vDSP_Length(frameCount))
        }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameCount))
        rms = min(1.0, rms)
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

        var indices = [Float](repeating: 0, count: outputCount)
        var base: Float = 0
        var step = Float(ratio)
        vDSP_vramp(&base, &step, &indices, 1, vDSP_Length(outputCount))

        var output = [Float](repeating: 0, count: outputCount)
        input.withUnsafeBufferPointer { buf in
            vDSP_vlint(buf.baseAddress!, &indices, 1, &output, 1, vDSP_Length(outputCount), vDSP_Length(input.count))
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
