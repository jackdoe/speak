#pragma once

#include <vector>
#include <cmath>

class VoiceActivityDetector {
public:
    enum class State { silence, speech_onset, speaking, speech_offset };

    State state = State::silence;
    bool is_speaking = false;
    bool is_enabled = true;

    float speech_threshold = 0.007f;
    float silence_threshold = 0.003f;
    int min_speech_duration_ms = 60;
    int min_silence_duration_ms = 600;
    int pre_speech_padding_ms = 200;
    int post_speech_padding_ms = 300;

    std::vector<float> process(const float* samples, size_t count, int sample_rate = 16000);
    void reset();

private:
    int active_sample_rate_ = 16000;
    std::vector<float> pre_speech_buf_;
    std::vector<float> onset_buf_;
    std::vector<float> post_speech_buf_;
    int speech_sample_count_ = 0;
    int silence_sample_count_ = 0;

    int pre_speech_max_samples() const { return pre_speech_padding_ms * active_sample_rate_ / 1000; }
    int post_speech_max_samples() const { return post_speech_padding_ms * active_sample_rate_ / 1000; }
    int min_speech_samples() const { return min_speech_duration_ms * active_sample_rate_ / 1000; }
    int min_silence_samples() const { return min_silence_duration_ms * active_sample_rate_ / 1000; }

    void process_frame(const float* frame, size_t len, std::vector<float>& output);
    void append_to_pre_speech(const float* data, size_t len);

    static float compute_rms(const float* data, size_t len) {
        if (len == 0) return 0;
        float sum = 0;
        for (size_t i = 0; i < len; ++i) sum += data[i] * data[i];
        return std::sqrt(sum / static_cast<float>(len));
    }
};
