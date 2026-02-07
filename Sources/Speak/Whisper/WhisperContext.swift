import Foundation
import CWhisper

enum WhisperError: Error, LocalizedError {
    case modelLoadFailed(String)
    case transcriptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "Failed to load whisper model at: \(path)"
        case .transcriptionFailed(let code):
            return "Whisper transcription failed with code: \(code)"
        }
    }
}

actor WhisperContext {
    private let ctx: OpaquePointer
    private let settings: WhisperSettings
    private let modelName: String

    init(modelPath: String, settings: WhisperSettings = WhisperSettings()) throws {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = settings.useGPU
        cparams.flash_attn = settings.flashAttention

        guard let context = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw WhisperError.modelLoadFailed(modelPath)
        }
        self.ctx = context
        self.settings = settings
        self.modelName = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
    }

    deinit {
        whisper_free(ctx)
    }

    func warmup() {
        NSLog("[WhisperContext] Warming up model...")
        let start = CFAbsoluteTimeGetCurrent()
        let silence = [Float](repeating: 0, count: 16000)
        _ = transcribe(samples: silence)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        NSLog("[WhisperContext] Warmup complete (%.0fms)", elapsed)
    }

    func transcribe(samples: [Float]) -> TranscriptionResult {
        let start = CFAbsoluteTimeGetCurrent()

        var params = whisper_full_default_params(settings.strategy.whisperStrategy)

        params.n_threads = Int32(settings.resolvedThreadCount)
        params.translate = settings.translate
        params.no_context = settings.noContext
        params.no_timestamps = settings.noTimestamps
        params.single_segment = settings.singleSegment
        params.token_timestamps = settings.tokenTimestamps
        params.suppress_blank = settings.suppressBlank
        params.suppress_nst = settings.suppressNonSpeechTokens
        params.temperature = settings.temperature
        params.entropy_thold = settings.entropyThreshold
        params.logprob_thold = settings.logprobThreshold
        params.no_speech_thold = settings.noSpeechThreshold
        params.greedy.best_of = Int32(settings.bestOf)
        params.beam_search.beam_size = Int32(settings.beamSize)
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false

        let languageCStr = settings.language.withCString { strdup($0) }
        params.language = UnsafePointer(languageCStr)
        defer { free(languageCStr) }

        let promptCStr: UnsafeMutablePointer<CChar>?
        if !settings.initialPrompt.isEmpty {
            promptCStr = settings.initialPrompt.withCString { strdup($0) }
            params.initial_prompt = UnsafePointer(promptCStr)
        } else {
            promptCStr = nil
            params.initial_prompt = nil
        }
        defer { free(promptCStr) }

        let result = samples.withUnsafeBufferPointer { buffer in
            whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        let audioDurationMs = Double(samples.count) / 16.0

        guard result == 0 else {
            return TranscriptionResult(
                segments: [],
                audioDurationMs: audioDurationMs,
                transcriptionTimeMs: elapsed,
                modelName: modelName
            )
        }

        let nSegments = whisper_full_n_segments(ctx)
        var segments: [TranscriptionSegment] = []
        segments.reserveCapacity(Int(nSegments))

        for i in 0..<nSegments {
            let text: String
            if let cStr = whisper_full_get_segment_text(ctx, i) {
                text = String(cString: cStr)
            } else {
                text = ""
            }
            let t0 = whisper_full_get_segment_t0(ctx, i) * 10
            let t1 = whisper_full_get_segment_t1(ctx, i) * 10
            segments.append(TranscriptionSegment(text: text, startTime: t0, endTime: t1))
        }

        return TranscriptionResult(
            segments: segments,
            audioDurationMs: audioDurationMs,
            transcriptionTimeMs: elapsed,
            modelName: modelName
        )
    }
}
