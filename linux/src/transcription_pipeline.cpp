#include "transcription_pipeline.h"
#include "text_output.h"
#include <algorithm>
#include <chrono>

static const char* HALLUCINATION_PATTERNS[] = {
    "thank you", "thanks for watching", "thanks for listening",
    "please subscribe", "like and subscribe", "see you next time",
    "bye bye", "goodbye", "the end"
};

TranscriptionPipeline::TranscriptionPipeline() {
    settings_ = Settings::load();
    apply_vad_settings();
}

TranscriptionPipeline::~TranscriptionPipeline() {
    shutdown();
}

void TranscriptionPipeline::apply_vad_settings() {
    auto& vad = audio_.vad();
    vad.is_enabled = settings_.vad_enabled;
    vad.speech_threshold = settings_.vad_speech_threshold;
    vad.silence_threshold = settings_.vad_silence_threshold;
    vad.min_speech_duration_ms = settings_.vad_min_speech_ms;
    vad.min_silence_duration_ms = settings_.vad_min_silence_ms;
    vad.pre_speech_padding_ms = settings_.vad_pre_padding_ms;
    vad.post_speech_padding_ms = settings_.vad_post_padding_ms;
}

void TranscriptionPipeline::start_recording() {
    if (recording_) return;
    last_context_text_.clear();
    did_output_ = false;
    audio_.start_recording();
    recording_ = true;

    if (settings_.transcription_mode == TranscriptionMode::continuous) {
        start_continuous_monitor();
        fprintf(stderr, "[Pipeline] Continuous monitor started\n");
    }

    fprintf(stderr, "[Pipeline] Recording started (mode: %s, vad: %s)\n",
            settings_.transcription_mode == TranscriptionMode::continuous ? "continuous" : "buffered",
            settings_.vad_enabled ? "on" : "off");
}

TranscriptionResult TranscriptionPipeline::stop_recording_and_transcribe() {
    if (!recording_) return {};

    stop_continuous_monitor();
    auto samples = audio_.stop_recording();
    if (!settings_.keep_mic_warm) audio_.release();
    recording_ = false;

    if (static_cast<int>(samples.size()) < MIN_SAMPLES) return {};

    return transcribe_and_output(samples);
}

void TranscriptionPipeline::shutdown() {
    stop_continuous_monitor();
    ctx_.reset();
    audio_.release();
}

void TranscriptionPipeline::load_model(const WhisperModel& model) {
    ctx_ = models_.load(model, settings_);
    ctx_->warmup();
    fprintf(stderr, "[Pipeline] Model loaded and warmed up: %s\n", model.name().c_str());
}

void TranscriptionPipeline::load_first_available() {
    ctx_ = models_.load_saved_or_first(settings_);
    ctx_->warmup();
    auto* m = models_.current();
    if (m) fprintf(stderr, "[Pipeline] Auto-loaded and warmed up: %s\n", m->name().c_str());
}

void TranscriptionPipeline::start_continuous_monitor() {
    silence_frame_count_ = 0;
    continuous_running_ = true;
    continuous_thread_ = std::thread(&TranscriptionPipeline::continuous_loop, this);
}

void TranscriptionPipeline::stop_continuous_monitor() {
    continuous_running_ = false;
    if (continuous_thread_.joinable()) continuous_thread_.join();
}

void TranscriptionPipeline::continuous_loop() {
    while (continuous_running_) {
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        if (!continuous_running_) break;

        auto& vad = audio_.vad();
        size_t buf_count = audio_.raw_buffer().count();

        if (vad.is_speaking) {
            silence_frame_count_ = 0;
        } else {
            ++silence_frame_count_;
        }

        bool pause_detected = buf_count > 0 && silence_frame_count_ >= 3;
        bool buffer_full = buf_count > static_cast<size_t>(audio_.hardware_sample_rate()) * 25;

        if ((!pause_detected && !buffer_full) || transcribing_) continue;

        size_t min_raw = static_cast<size_t>(CONTINUOUS_MIN_SAMPLES * audio_.hardware_sample_rate() / 16000);
        if (buf_count < min_raw) continue;

        auto raw = audio_.raw_buffer().drain();
        auto resampled = audio_.resample_public(raw);

        fprintf(stderr, "[Pipeline] Continuous: %zu samples (%.1fs)\n",
                resampled.size(), static_cast<double>(resampled.size()) / 16000.0);

        if (!ctx_) continue;
        transcribing_ = true;
        if (on_transcription_start) on_transcription_start();

        const std::string* prompt_ptr = nullptr;
        std::string prompt;
        if (!last_context_text_.empty()) {
            size_t start = last_context_text_.size() > 200 ? last_context_text_.size() - 200 : 0;
            prompt = last_context_text_.substr(start);
            prompt_ptr = &prompt;
        }

        auto result = ctx_->transcribe(resampled, prompt_ptr);
        transcribing_ = false;

        std::string text = result.full_text();
        while (!text.empty() && (text.front() == ' ' || text.front() == '\n')) text.erase(text.begin());
        while (!text.empty() && (text.back() == ' ' || text.back() == '\n')) text.pop_back();

        if (text.empty() || is_hallucination(text)) {
            if (!text.empty()) fprintf(stderr, "[Pipeline] Filtered hallucination\n");
            if (on_transcription_end) on_transcription_end();
            continue;
        }

        last_context_text_ += " " + text;
        if (last_context_text_.size() > 500) {
            last_context_text_ = last_context_text_.substr(last_context_text_.size() - 300);
        }

        perf_.record(result);
        output_text(text + " ");

        fprintf(stderr, "[Pipeline] Continuous: %zu chars (%.0fms, RTF: %.2f)\n",
                text.size(), result.transcription_time_ms, result.real_time_factor());

        if (on_transcription_end) on_transcription_end();
    }
}

bool TranscriptionPipeline::is_hallucination(const std::string& text) {
    std::string lower = text;
    for (auto& c : lower) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    while (!lower.empty() && (lower.front() == ' ' || lower.front() == '\n')) lower.erase(lower.begin());
    while (!lower.empty() && (lower.back() == ' ' || lower.back() == '\n')) lower.pop_back();

    if (lower.size() < 3) return true;
    for (auto& pattern : HALLUCINATION_PATTERNS) {
        if (lower.find(pattern) != std::string::npos) return true;
    }
    return false;
}

TranscriptionResult TranscriptionPipeline::transcribe_and_output(const std::vector<float>& samples) {
    if (!ctx_) return {};

    transcribing_ = true;
    if (on_transcription_start) on_transcription_start();

    TranscriptionResult result;
    if (static_cast<int>(samples.size()) > MAX_CHUNK_SAMPLES) {
        result = transcribe_chunked(samples);
    } else {
        result = ctx_->transcribe(samples);
    }

    perf_.record(result);
    transcribing_ = false;

    fprintf(stderr, "[Pipeline] Transcription: %zu chars (%.0fms, RTF: %.2f)\n",
            result.full_text().size(), result.transcription_time_ms, result.real_time_factor());

    std::string text = result.full_text();
    while (!text.empty() && (text.front() == ' ' || text.front() == '\n')) text.erase(text.begin());
    while (!text.empty() && (text.back() == ' ' || text.back() == '\n')) text.pop_back();

    if (!text.empty()) output_text(text);

    if (on_transcription_end) on_transcription_end();
    return result;
}

void TranscriptionPipeline::output_text(const std::string& text) {
    did_output_ = true;
    if (settings_.output_mode == OutputMode::type) {
        TextOutput::type(text, settings_.type_speed_ms);
    } else {
        TextOutput::paste(text, settings_.restore_clipboard);
    }
}

TranscriptionResult TranscriptionPipeline::transcribe_chunked(const std::vector<float>& samples) {
    auto start = std::chrono::steady_clock::now();
    std::vector<TranscriptionSegment> all_segments;
    double total_audio_ms = static_cast<double>(samples.size()) / 16.0;

    size_t offset = 0;
    while (offset < samples.size()) {
        size_t end = std::min(offset + static_cast<size_t>(MAX_CHUNK_SAMPLES), samples.size());
        std::vector<float> chunk(samples.begin() + offset, samples.begin() + end);
        auto chunk_result = ctx_->transcribe(chunk);

        int64_t offset_ms = static_cast<int64_t>(static_cast<double>(offset) / 16.0);
        for (auto& seg : chunk_result.segments) {
            all_segments.push_back({seg.text, seg.start_time + offset_ms, seg.end_time + offset_ms});
        }
        offset = end;
    }

    double elapsed = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - start).count();

    auto* m = models_.current();
    return {std::move(all_segments), total_audio_ms, elapsed, m ? m->name() : "unknown"};
}
