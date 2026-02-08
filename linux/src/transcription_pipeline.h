#pragma once

#include "audio_engine.h"
#include "model_manager.h"
#include "whisper_context.h"
#include "performance_monitor.h"
#include "settings.h"
#include <memory>
#include <atomic>
#include <thread>
#include <functional>

class TranscriptionPipeline {
public:
    TranscriptionPipeline();
    ~TranscriptionPipeline();

    AudioEngine& audio_engine() { return audio_; }
    ModelManager& model_manager() { return models_; }
    PerformanceMonitor& perf() { return perf_; }
    Settings& settings() { return settings_; }

    bool is_recording() const { return recording_; }
    bool is_transcribing() const { return transcribing_; }
    bool did_output_text() const { return did_output_; }

    void apply_vad_settings();
    void start_recording();
    TranscriptionResult stop_recording_and_transcribe();
    void shutdown();

    void load_model(const WhisperModel& model);
    void load_first_available();

    std::function<void()> on_transcription_start;
    std::function<void()> on_transcription_end;

private:
    AudioEngine audio_;
    ModelManager models_;
    PerformanceMonitor perf_;
    Settings settings_;
    std::unique_ptr<WhisperContext> ctx_;
    std::string last_context_text_;
    std::atomic<bool> recording_{false};
    std::atomic<bool> transcribing_{false};
    bool did_output_ = false;

    std::thread continuous_thread_;
    std::atomic<bool> continuous_running_{false};
    int silence_frame_count_ = 0;

    static constexpr int MAX_CHUNK_SAMPLES = 480'000;
    static constexpr int MIN_SAMPLES = 8'000;
    static constexpr int CONTINUOUS_MIN_SAMPLES = 24'000;

    static bool is_hallucination(const std::string& text);
    void output_text(const std::string& text);
    TranscriptionResult transcribe_and_output(const std::vector<float>& samples);
    TranscriptionResult transcribe_chunked(const std::vector<float>& samples);

    void start_continuous_monitor();
    void stop_continuous_monitor();
    void continuous_loop();
};
