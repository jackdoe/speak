import Foundation

@Observable
class VoiceActivityDetector {

    enum State {
        case silence
        case speechOnset
        case speaking
        case speechOffset
    }

    var state: State = .silence
    var isSpeaking: Bool = false
    var isEnabled: Bool = true

    var speechThreshold: Float
    var silenceThreshold: Float
    var minSpeechDurationMs: Int
    var minSilenceDurationMs: Int
    var preSpeechPaddingMs: Int
    var postSpeechPaddingMs: Int

    private var activeSampleRate: Int = 16000

    private var preSpeechBuffer: [Float] = []
    private var preSpeechMaxSamples: Int { preSpeechPaddingMs * activeSampleRate / 1000 }

    private var onsetBuffer: [Float] = []

    private var speechSampleCount: Int = 0
    private var silenceSampleCount: Int = 0

    private var postSpeechBuffer: [Float] = []
    private var postSpeechMaxSamples: Int { postSpeechPaddingMs * activeSampleRate / 1000 }

    private var minSpeechSamples: Int { minSpeechDurationMs * activeSampleRate / 1000 }
    private var minSilenceSamples: Int { minSilenceDurationMs * activeSampleRate / 1000 }

    init(settings: WhisperSettings = WhisperSettings()) {
        self.speechThreshold = settings.vadSpeechThreshold
        self.silenceThreshold = settings.vadSilenceThreshold
        self.minSpeechDurationMs = settings.vadMinSpeechMs
        self.minSilenceDurationMs = settings.vadMinSilenceMs
        self.preSpeechPaddingMs = settings.vadPrePaddingMs
        self.postSpeechPaddingMs = settings.vadPostPaddingMs
    }

    func process(samples: [Float], sampleRate: Int = 16000) -> [Float] {
        guard isEnabled else { return samples }

        activeSampleRate = sampleRate
        let frameSize = sampleRate * 30 / 1000
        var output: [Float] = []
        var offset = 0

        while offset < samples.count {
            let end = min(offset + frameSize, samples.count)
            let frame = Array(samples[offset..<end])
            let frameOutput = processFrame(frame)
            output.append(contentsOf: frameOutput)
            offset = end
        }

        return output
    }

    func reset() {
        state = .silence
        isSpeaking = false
        preSpeechBuffer.removeAll(keepingCapacity: true)
        onsetBuffer.removeAll(keepingCapacity: true)
        postSpeechBuffer.removeAll(keepingCapacity: true)
        speechSampleCount = 0
        silenceSampleCount = 0
    }

    private func processFrame(_ frame: [Float]) -> [Float] {
        let rms = computeRMS(frame)
        var output: [Float] = []

        switch state {
        case .silence:
            if rms >= speechThreshold {
                state = .speechOnset
                speechSampleCount = frame.count
                onsetBuffer = frame
            } else {
                appendToPreSpeechBuffer(frame)
            }

        case .speechOnset:
            if rms >= speechThreshold {
                speechSampleCount += frame.count
                onsetBuffer.append(contentsOf: frame)

                if speechSampleCount >= minSpeechSamples {
                    state = .speaking
                    isSpeaking = true
                    output.append(contentsOf: preSpeechBuffer)
                    output.append(contentsOf: onsetBuffer)
                    preSpeechBuffer.removeAll(keepingCapacity: true)
                    onsetBuffer.removeAll(keepingCapacity: true)
                }
            } else {
                appendToPreSpeechBuffer(onsetBuffer)
                appendToPreSpeechBuffer(frame)
                onsetBuffer.removeAll(keepingCapacity: true)
                speechSampleCount = 0
                state = .silence
            }

        case .speaking:
            if rms < silenceThreshold {
                state = .speechOffset
                silenceSampleCount = frame.count
                postSpeechBuffer = frame
            } else {
                output.append(contentsOf: frame)
            }

        case .speechOffset:
            if rms < silenceThreshold {
                silenceSampleCount += frame.count
                postSpeechBuffer.append(contentsOf: frame)

                if silenceSampleCount >= minSilenceSamples {
                    let paddingSamples = min(postSpeechMaxSamples, postSpeechBuffer.count)
                    output.append(contentsOf: Array(postSpeechBuffer.prefix(paddingSamples)))
                    postSpeechBuffer.removeAll(keepingCapacity: true)
                    silenceSampleCount = 0
                    state = .silence
                    isSpeaking = false
                    preSpeechBuffer.removeAll(keepingCapacity: true)
                }
            } else {
                output.append(contentsOf: postSpeechBuffer)
                output.append(contentsOf: frame)
                postSpeechBuffer.removeAll(keepingCapacity: true)
                silenceSampleCount = 0
                state = .speaking
            }
        }

        return output
    }

    private func appendToPreSpeechBuffer(_ samples: [Float]) {
        preSpeechBuffer.append(contentsOf: samples)
        let maxSamples = preSpeechMaxSamples
        if preSpeechBuffer.count > maxSamples {
            preSpeechBuffer.removeFirst(preSpeechBuffer.count - maxSamples)
        }
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        return sqrtf(sumSquares / Float(samples.count))
    }
}
