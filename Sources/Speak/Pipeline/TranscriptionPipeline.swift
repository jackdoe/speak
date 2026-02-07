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

    private var whisperContext: WhisperContext?

    private static let maxChunkSamples = 480_000
    private static let minSamples = 8_000

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
        do {
            try audioEngine.startRecording()
            isRecording = true
            NSLog("[Pipeline] Recording started")
        } catch {
            NSLog("[Pipeline] Failed to start recording: %@", error.localizedDescription)
        }
    }

    func stopRecordingAndTranscribe() async -> TranscriptionResult? {
        guard isRecording else { return nil }

        let samples = audioEngine.stopRecording()
        if !settings.keepMicWarm {
            audioEngine.releaseEngine()
        }
        isRecording = false
        NSLog("[Pipeline] Recording stopped, got %d samples (%.1fs)", samples.count, Double(samples.count) / 16000.0)

        guard samples.count >= Self.minSamples else {
            NSLog("[Pipeline] Audio too short (%d samples), skipping", samples.count)
            return nil
        }

        guard let ctx = whisperContext else {
            NSLog("[Pipeline] No model loaded, cannot transcribe")
            return nil
        }

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

        NSLog("[Pipeline] Transcription done: \"%@\" (%.0fms, RTF: %.2f)",
              result.fullText, result.transcriptionTimeMs, result.realTimeFactor)

        let text = result.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            switch settings.outputMode {
            case .type:
                TextOutput.type(text, delayMs: settings.typeSpeedMs)
            case .paste:
                TextOutput.paste(text, restoreClipboard: settings.restoreClipboard)
            }
        }

        return result
    }

    func shutdown() {
        whisperContext = nil
        modelManager.releaseContext()
        NSLog("[Pipeline] Shutdown, context released")
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
        NSLog("[Pipeline] Chunked transcription: %d chunks, %.0fms total", chunkIndex, elapsed)

        return TranscriptionResult(
            segments: allSegments,
            audioDurationMs: totalAudioDurationMs,
            transcriptionTimeMs: elapsed,
            modelName: modelManager.currentModel?.name ?? "unknown"
        )
    }
}
