import Foundation
import Observation
import Accelerate

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
    private static let overlapSamples = 24_000
    private static let minSamples = 8_000
    private static let continuousMinSamples = 24_000

    private static let hallucinationPhrases: Set<String> = [
        "thank you", "thanks for watching", "thanks for listening",
        "please subscribe", "like and subscribe", "see you next time",
        "bye bye", "goodbye", "the end", "thanks for joining",
        "thanks for tuning in", "see you in the next video",
        "don't forget to subscribe", "hit the bell",
        "leave a comment", "share this video",
        "thanks for your support", "see you soon",
        "take care", "have a nice day", "have a great day",
        "good night", "good morning", "good evening",
        "welcome back", "hello everyone", "hi everyone",
        "let's get started", "without further ado",
        "as always", "as you can see", "as i mentioned",
        "you know what i mean", "if you know what i mean",
        "at the end of the day", "long story short",
        "having said that", "that being said",
        "in conclusion", "to sum up", "to summarize",
        "last but not least", "first and foremost",
        "ladies and gentlemen", "dear friends",
        "my fellow americans", "god bless you",
        "amen", "hallelujah", "oh my god",
        "subtitles by", "translated by", "captioned by",
        "copyright", "all rights reserved",
        "music", "applause", "laughter",
    ]

    init() {
        applyVADSettings()
    }

    func applyVADSettings() {
        let vad = audioEngine.voiceActivityDetector
        vad.isEnabled = settings.vadEnabled
        vad.passthrough = settings.sileroVADEnabled
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

            let text = result.filteredText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !Self.isHallucination(text) else {
                if !text.isEmpty { NSLog("[Pipeline] Filtered hallucination") }
                return
            }

            if Self.isPromptEcho(text, context: self.lastContextText) {
                NSLog("[Pipeline] Filtered prompt echo")
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

    private static func isPromptEcho(_ text: String, context: String) -> Bool {
        guard context.count >= 10 else { return false }
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 10 else { return false }
        let c = context.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return c.contains(t)
    }

    private static func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.count < 3 { return true }
        if hallucinationPhrases.contains(lower) { return true }
        if hasRepetitiveNGrams(lower) { return true }
        return false
    }

    private static func hasRepetitiveNGrams(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard words.count >= 9 else { return false }
        var counts: [String: Int] = [:]
        for i in 0...(words.count - 3) {
            let trigram = words[i..<(i + 3)].joined(separator: " ")
            counts[trigram, default: 0] += 1
            if counts[trigram]! >= 3 { return true }
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
              result.filteredText.count, result.transcriptionTimeMs, result.realTimeFactor)

        let text = result.filteredText.trimmingCharacters(in: .whitespacesAndNewlines)
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
        var previousSuffix: String?
        while offset < samples.count {
            let rawEnd = min(offset + Self.maxChunkSamples, samples.count)
            let end = findQuietBoundary(in: samples, near: rawEnd)
            let chunk = Array(samples[offset..<end])
            let chunkResult = await ctx.transcribe(samples: chunk, contextPrompt: previousSuffix)

            let chunkText = chunkResult.filteredText
            let offsetMs = Int64(Double(offset) / 16.0)

            var deduped = chunkResult.segments
            if let prev = previousSuffix {
                deduped = deduplicateOverlap(previous: prev, segments: deduped)
            }

            for segment in deduped {
                allSegments.append(TranscriptionSegment(
                    text: segment.text,
                    startTime: segment.startTime + offsetMs,
                    endTime: segment.endTime + offsetMs,
                    noSpeechProb: segment.noSpeechProb,
                    avgTokenProb: segment.avgTokenProb
                ))
            }

            previousSuffix = String(chunkText.suffix(200))
            let nextOffset = end - Self.overlapSamples
            if samples.count - nextOffset < Self.overlapSamples {
                break
            }
            offset = nextOffset
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        return TranscriptionResult(
            segments: allSegments,
            audioDurationMs: totalAudioDurationMs,
            transcriptionTimeMs: elapsed,
            modelName: modelManager.currentModel?.name ?? "unknown"
        )
    }

    private func findQuietBoundary(in samples: [Float], near target: Int) -> Int {
        let searchStart = max(0, target - 48_000)
        guard searchStart < target else { return target }

        let window = 1600
        var quietestPos = target
        var quietestRMS: Float = .greatestFiniteMagnitude

        var pos = searchStart
        while pos + window <= target {
            var rms: Float = 0
            samples.withUnsafeBufferPointer { buf in
                vDSP_rmsqv(buf.baseAddress! + pos, 1, &rms, vDSP_Length(window))
            }
            if rms < quietestRMS {
                quietestRMS = rms
                quietestPos = pos + window
            }
            pos += window
        }
        return quietestPos
    }

    private func deduplicateOverlap(previous: String, segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        guard !segments.isEmpty else { return segments }
        let prevWords = previous.lowercased().split(separator: " ").suffix(10)
        guard prevWords.count >= 3 else { return segments }

        let firstText = segments[0].text.lowercased()
        let firstWords = firstText.split(separator: " ")

        var bestMatch = 0
        for len in stride(from: min(prevWords.count, firstWords.count), through: 3, by: -1) {
            if Array(prevWords.suffix(len)) == Array(firstWords.prefix(len)) {
                bestMatch = len
                break
            }
        }

        guard bestMatch > 0 else { return segments }

        let trimmedFirst = firstWords.dropFirst(bestMatch).joined(separator: " ")
        if trimmedFirst.trimmingCharacters(in: .whitespaces).isEmpty {
            return Array(segments.dropFirst())
        }

        var result = segments
        let original = segments[0]
        result[0] = TranscriptionSegment(
            text: " " + trimmedFirst,
            startTime: original.startTime,
            endTime: original.endTime,
            noSpeechProb: original.noSpeechProb,
            avgTokenProb: original.avgTokenProb
        )
        return result
    }
}
