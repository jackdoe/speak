#include "whisper_context.h"
#include "whisper.h"
#include <chrono>
#include <stdexcept>
#include <filesystem>
#include <cstring>

WhisperContext::WhisperContext(const std::string& model_path, const Settings& settings)
    : settings_(settings) {

    auto cparams = whisper_context_default_params();
    cparams.use_gpu = settings.use_gpu;
    cparams.flash_attn = settings.flash_attention;

    ctx_ = whisper_init_from_file_with_params(model_path.c_str(), cparams);
    if (!ctx_) throw std::runtime_error("Failed to load whisper model: " + model_path);

    model_name_ = std::filesystem::path(model_path).stem().string();
}

WhisperContext::~WhisperContext() {
    if (ctx_) whisper_free(ctx_);
}

void WhisperContext::warmup() {
    fprintf(stderr, "[WhisperContext] Warming up model...\n");
    auto start = std::chrono::steady_clock::now();
    std::vector<float> silence(16000, 0.0f);
    transcribe(silence);
    auto elapsed = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - start).count();
    fprintf(stderr, "[WhisperContext] Warmup complete (%.0fms)\n", elapsed);
}

TranscriptionResult WhisperContext::transcribe(const std::vector<float>& samples, const std::string* context_prompt) {
    std::lock_guard<std::mutex> lk(mu_);

    auto start = std::chrono::steady_clock::now();

    auto params = whisper_full_default_params(
        settings_.strategy == SamplingStrategy::beam_search
            ? WHISPER_SAMPLING_BEAM_SEARCH
            : WHISPER_SAMPLING_GREEDY);

    params.n_threads = settings_.resolved_thread_count();
    params.translate = settings_.translate;
    params.no_context = (context_prompt == nullptr) ? settings_.no_context : false;
    params.no_timestamps = settings_.no_timestamps;
    params.single_segment = settings_.single_segment;
    params.token_timestamps = settings_.token_timestamps;
    params.suppress_blank = settings_.suppress_blank;
    params.suppress_nst = settings_.suppress_non_speech_tokens;
    params.temperature = settings_.temperature;
    params.entropy_thold = settings_.entropy_threshold;
    params.logprob_thold = settings_.logprob_threshold;
    params.no_speech_thold = settings_.no_speech_threshold;
    params.greedy.best_of = settings_.best_of;
    params.beam_search.beam_size = settings_.beam_size;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;

    params.language = settings_.language.c_str();

    const std::string* prompt = context_prompt;
    std::string fallback;
    if (!prompt && !settings_.initial_prompt.empty()) {
        fallback = settings_.initial_prompt;
        prompt = &fallback;
    }
    params.initial_prompt = prompt ? prompt->c_str() : nullptr;

    int result = whisper_full(ctx_, params, samples.data(), static_cast<int>(samples.size()));

    auto elapsed = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - start).count();
    double audio_ms = static_cast<double>(samples.size()) / 16.0;

    TranscriptionResult tr;
    tr.audio_duration_ms = audio_ms;
    tr.transcription_time_ms = elapsed;
    tr.model_name = model_name_;

    if (result != 0) return tr;

    int n_segments = whisper_full_n_segments(ctx_);
    tr.segments.reserve(n_segments);

    for (int i = 0; i < n_segments; ++i) {
        const char* text = whisper_full_get_segment_text(ctx_, i);
        int64_t t0 = whisper_full_get_segment_t0(ctx_, i) * 10;
        int64_t t1 = whisper_full_get_segment_t1(ctx_, i) * 10;
        tr.segments.push_back({text ? text : "", t0, t1});
    }

    return tr;
}
