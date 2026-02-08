#pragma once

#include "ring_buffer.h"
#include "vad.h"
#include <atomic>
#include <thread>
#include <string>
#include <functional>
#include <pulse/simple.h>

class AudioEngine {
public:
    ~AudioEngine();

    std::string device;

    void prepare();
    void start_recording();
    std::vector<float> stop_recording();
    void release();

    VoiceActivityDetector& vad() { return vad_; }
    RingBuffer& raw_buffer() { return buffer_; }
    double hardware_sample_rate() const { return hardware_sr_; }
    std::atomic<float>& audio_level() { return audio_level_; }

    std::vector<float> resample_public(const std::vector<float>& input);

    static void list_devices();

private:
    pa_simple* pa_ = nullptr;
    VoiceActivityDetector vad_;
    RingBuffer buffer_;
    double hardware_sr_ = 48000;
    std::atomic<bool> running_{false};
    std::atomic<bool> collecting_{false};
    std::atomic<float> audio_level_{0};
    std::thread capture_thread_;

    void capture_loop();
    static std::vector<float> resample(const std::vector<float>& input, double from, double to);
};
