import Foundation
import Observation

@Observable
class TranscriptionPipeline {
    let audioEngine = AudioEngine()
    let modelManager = ModelManager()
    var settings = WhisperSettings.load() {
        didSet { applyVADSettings() }
    }
    let performanceMonitor = PerformanceMonitor()

    var isRecording = false
    var isTranscribing = false
    var lastResult: TranscriptionResult?
    private(set) var didOutputText = false

    private var whisperContext: WhisperContext?
    private var lastContextText = ""
    private var continuousTimer: Timer?
    private var silenceFrameCount = 0

    private static let maxChunkSamples = 480_000
    private static let minSamples = 8_000
    private static let continuousMinSamples = 24_000  // 1.5s at 16kHz

    private static let hallucinationPatterns = [
        "thank you", "thanks for watching", "thanks for listening",
        "please subscribe", "like and subscribe", "see you next time",
        "bye bye", "goodbye", "the end"
    ]

    init() {
        applyVADSettings()
    }

    func applyVADSettings() {
        let vad = audioEngine.voiceActivityDetector
        vad.isEnabled = settings.vadEnabled
        vad.speechThreshold = settings.vadSpeechThreshold
        vad.silenceThreshold = settings.vadSilenceThreshold
        vad.minSpeechDurationMs = settings.vadMinSpeechMs
        vad.minSilenceDurationMs = settings.vadMinSilenceMs
        vad.preSpeechPaddingMs = settings.vadPrePaddingMs
        vad.postSpeechPaddingMs = settings.vadPostPaddingMs
    }

    func startRecording() {
        guard !isRecording else { return }
        lastContextText = ""
        didOutputText = false
        do {
            try audioEngine.startRecording()
            isRecording = true
            if settings.transcriptionMode == .continuous {
                startContinuousMonitor()
                NSLog("[Pipeline] Continuous monitor started")
            }
            NSLog("[Pipeline] Recording started (mode: %@, vad: %@)",
                  settings.transcriptionMode.rawValue,
                  settings.vadEnabled ? "on" : "off")
        } catch {
            NSLog("[Pipeline] Failed to start recording: %@", error.localizedDescription)
        }
    }

    func stopRecordingAndTranscribe() async -> TranscriptionResult? {
        guard isRecording else { return nil }

        stopContinuousMonitor()
        let samples = audioEngine.stopRecording()
        if !settings.keepMicWarm {
            audioEngine.releaseEngine()
        }
        isRecording = false

        guard samples.count >= Self.minSamples else {
            return nil
        }

        let result = await transcribeAndOutput(samples: samples)
        return result
    }

    func shutdown() {
        stopContinuousMonitor()
        whisperContext = nil
        modelManager.releaseContext()
    }

    func loadModel(_ model: WhisperModel) async throws {
        let ctx = try await modelManager.loadModel(model, settings: settings)
        await ctx.warmup()
        whisperContext = ctx
        NSLog("[Pipeline] Model loaded and warmed up: %@", model.name)
    }

    func loadFirstAvailableModel() async throws {
        let ctx = try await modelManager.loadSavedOrFirstAvailable(settings: settings)
        await ctx.warmup()
        whisperContext = ctx
        if let model = modelManager.currentModel {
            NSLog("[Pipeline] Auto-loaded and warmed up model: %@", model.name)
        }
    }

    private func startContinuousMonitor() {
        silenceFrameCount = 0
        continuousTimer?.invalidate()
        continuousTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.checkVADAndTranscribe()
        }
    }

    private func stopContinuousMonitor() {
        continuousTimer?.invalidate()
        continuousTimer = nil
    }

    private func checkVADAndTranscribe() {
        let vad = audioEngine.voiceActivityDetector
        let bufferCount = audioEngine.rawBuffer.count

        if vad.isSpeaking {
            silenceFrameCount = 0
        } else {
            silenceFrameCount += 1
        }

        let pauseDetected = bufferCount > 0 && silenceFrameCount >= 3
        let bufferFull = bufferCount > Int(audioEngine.hardwareSampleRate) * 25

        guard (pauseDetected || bufferFull) && !isTranscribing else { return }

        let samples = audioEngine.rawBuffer.drain()
        let resampled = audioEngine.resamplePublic(samples)

        guard resampled.count >= Self.continuousMinSamples else { return }

        NSLog("[Pipeline] Continuous: %d samples (%.1fs)",
              resampled.count, Double(resampled.count) / 16000.0)

        Task { @MainActor in
            guard let ctx = self.whisperContext else { return }
            self.isTranscribing = true

            let prompt = self.lastContextText.isEmpty ? nil : String(self.lastContextText.suffix(200))
            let result = await ctx.transcribe(samples: resampled, contextPrompt: prompt)

            self.isTranscribing = false

            let text = result.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !Self.isHallucination(text) else {
                if !text.isEmpty { NSLog("[Pipeline] Filtered hallucination") }
                return
            }

            self.lastContextText += " " + text
            if self.lastContextText.count > 500 {
                self.lastContextText = String(self.lastContextText.suffix(300))
            }

            self.lastResult = result
            self.performanceMonitor.record(result)
            self.outputText(text + " ")

            NSLog("[Pipeline] Continuous: %d chars (%.0fms, RTF: %.2f)",
                  text.count, result.transcriptionTimeMs, result.realTimeFactor)
        }
    }

    private static func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.count < 3 { return true }
        for pattern in hallucinationPatterns {
            if lower.contains(pattern) { return true }
        }
        return false
    }

    private func transcribeAndOutput(samples: [Float]) async -> TranscriptionResult? {
        guard let ctx = whisperContext else { return nil }

        isTranscribing = true
        defer { isTranscribing = false }

        let result: TranscriptionResult
        if samples.count > Self.maxChunkSamples {
            result = await transcribeChunked(ctx: ctx, samples: samples)
        } else {
            result = await ctx.transcribe(samples: samples)
        }

        lastResult = result
        performanceMonitor.record(result)

        NSLog("[Pipeline] Transcription: %d chars (%.0fms, RTF: %.2f)",
              result.fullText.count, result.transcriptionTimeMs, result.realTimeFactor)

        let text = result.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            outputText(text)
        }

        return result
    }

    private func outputText(_ text: String) {
        didOutputText = true
        switch settings.outputMode {
        case .type:
            TextOutput.type(text, delayMs: settings.typeSpeedMs)
        case .paste:
            TextOutput.paste(text, restoreClipboard: settings.restoreClipboard)
        }
    }

    private func transcribeChunked(ctx: WhisperContext, samples: [Float]) async -> TranscriptionResult {
        let start = CFAbsoluteTimeGetCurrent()
        var allSegments: [TranscriptionSegment] = []
        let totalAudioDurationMs = Double(samples.count) / 16.0

        var offset = 0
        var chunkIndex = 0
        while offset < samples.count {
            let end = min(offset + Self.maxChunkSamples, samples.count)
            let chunk = Array(samples[offset..<end])
            let chunkResult = await ctx.transcribe(samples: chunk)

            let offsetMs = Int64(Double(offset) / 16.0)
            for segment in chunkResult.segments {
                allSegments.append(TranscriptionSegment(
                    text: segment.text,
                    startTime: segment.startTime + offsetMs,
                    endTime: segment.endTime + offsetMs
                ))
            }

            chunkIndex += 1
            offset = end
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        return TranscriptionResult(
            segments: allSegments,
            audioDurationMs: totalAudioDurationMs,
            transcriptionTimeMs: elapsed,
            modelName: modelManager.currentModel?.name ?? "unknown"
        )
    }
}
