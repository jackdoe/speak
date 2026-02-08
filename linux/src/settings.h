#pragma once

#include <string>
#include <cstdint>
#include <thread>

enum class SamplingStrategy { greedy, beam_search };
enum class OutputMode { type, paste };
enum class TranscriptionMode { buffered, continuous };

struct Settings {
    SamplingStrategy strategy = SamplingStrategy::greedy;
    float temperature = 0.0f;
    int best_of = 5;
    int beam_size = 5;

    std::string language = "en";
    bool translate = false;

    int thread_count = 0;
    bool use_gpu = true;
    bool flash_attention = true;

    bool no_context = true;
    bool single_segment = false;
    bool no_timestamps = false;
    bool token_timestamps = false;
    bool suppress_blank = true;
    bool suppress_non_speech_tokens = true;
    std::string initial_prompt;

    float entropy_threshold = 2.4f;
    float logprob_threshold = -1.0f;
    float no_speech_threshold = 0.6f;

    bool vad_enabled = true;
    float vad_speech_threshold = 0.007f;
    float vad_silence_threshold = 0.003f;
    int vad_min_speech_ms = 30;
    int vad_min_silence_ms = 600;
    int vad_pre_padding_ms = 200;
    int vad_post_padding_ms = 300;

    OutputMode output_mode = OutputMode::type;
    int type_speed_ms = 5;
    bool restore_clipboard = true;
    int send_return_delay_ms = 200;

    uint32_t hotkey_keysym = 0xFFC9;      // XK_F12
    uint32_t send_hotkey_keysym = 0xFFC8;  // XK_F11
    bool keep_mic_warm = true;

    TranscriptionMode transcription_mode = TranscriptionMode::continuous;
    int release_delay_ms = 300;

    bool launch_at_login = false;

    int resolved_thread_count() const {
        if (thread_count > 0) return thread_count;
        int hw = static_cast<int>(std::thread::hardware_concurrency());
        int n = hw - 2;
        if (n < 1) n = 1;
        if (n > 8) n = 8;
        return n;
    }

    static std::string config_path();
    static Settings load();
    void save() const;
};
