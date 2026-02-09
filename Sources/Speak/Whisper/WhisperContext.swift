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

    func transcribe(samples: [Float], contextPrompt: String? = nil) -> TranscriptionResult {
        let start = CFAbsoluteTimeGetCurrent()

        var params = whisper_full_default_params(settings.strategy.whisperStrategy)

        params.n_threads = Int32(settings.resolvedThreadCount)
        params.translate = settings.translate
        params.no_context = contextPrompt == nil ? settings.noContext : false
        params.no_timestamps = settings.noTimestamps
        params.single_segment = settings.singleSegment
        params.token_timestamps = settings.tokenTimestamps
        params.suppress_blank = settings.suppressBlank
        params.suppress_nst = settings.suppressNonSpeechTokens
        params.temperature = settings.temperature
        params.temperature_inc = settings.temperatureInc
        params.carry_initial_prompt = settings.carryInitialPrompt
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

        let prompt = contextPrompt ?? (settings.initialPrompt.isEmpty ? nil : settings.initialPrompt)
        let promptCStr: UnsafeMutablePointer<CChar>?
        if let prompt = prompt {
            promptCStr = prompt.withCString { strdup($0) }
            params.initial_prompt = UnsafePointer(promptCStr)
        } else {
            promptCStr = nil
            params.initial_prompt = nil
        }
        defer { free(promptCStr) }

        let vadModelPath = ModelManager.vadModelPath
        let vadCStr: UnsafeMutablePointer<CChar>?
        if settings.sileroVADEnabled && ModelManager.vadModelExists {
            params.vad = true
            vadCStr = vadModelPath.withCString { strdup($0) }
            params.vad_model_path = UnsafePointer(vadCStr)
        } else {
            vadCStr = nil
        }
        defer { free(vadCStr) }

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

            let noSpeechProb = whisper_full_get_segment_no_speech_prob(ctx, i)

            let nTokens = whisper_full_n_tokens(ctx, i)
            var tokenProbSum: Float = 0
            for j in 0..<nTokens {
                tokenProbSum += whisper_full_get_token_p(ctx, i, j)
            }
            let avgTokenProb = nTokens > 0 ? tokenProbSum / Float(nTokens) : 0

            segments.append(TranscriptionSegment(
                text: text,
                startTime: t0,
                endTime: t1,
                noSpeechProb: noSpeechProb,
                avgTokenProb: avgTokenProb
            ))
        }

        return TranscriptionResult(
            segments: segments,
            audioDurationMs: audioDurationMs,
            transcriptionTimeMs: elapsed,
            modelName: modelName
        )
    }
}
