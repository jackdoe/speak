#include "audio_engine.h"
#include <pulse/simple.h>
#include <pulse/error.h>
#include <pulse/pulseaudio.h>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <chrono>

AudioEngine::~AudioEngine() {
    release();
}

static void source_info_cb(pa_context*, const pa_source_info* info, int eol, void* userdata) {
    if (eol || !info) return;
    auto* out = static_cast<std::vector<std::pair<std::string,std::string>>*>(userdata);
    std::string desc = info->description ? info->description : "";
    out->push_back({info->name, desc});
}

void AudioEngine::list_devices() {
    pa_mainloop* ml = pa_mainloop_new();
    pa_context* ctx = pa_context_new(pa_mainloop_get_api(ml), "speak-list");
    pa_context_connect(ctx, nullptr, PA_CONTEXT_NOFLAGS, nullptr);

    bool ready = false;
    for (int i = 0; i < 100; ++i) {
        pa_mainloop_iterate(ml, 0, nullptr);
        if (pa_context_get_state(ctx) == PA_CONTEXT_READY) { ready = true; break; }
        if (pa_context_get_state(ctx) == PA_CONTEXT_FAILED) break;
        struct timespec ts{0, 10000000};
        nanosleep(&ts, nullptr);
    }

    if (!ready) {
        fprintf(stderr, "Cannot connect to PulseAudio/PipeWire\n");
        pa_context_unref(ctx);
        pa_mainloop_free(ml);
        return;
    }

    std::vector<std::pair<std::string,std::string>> sources;
    pa_operation* op = pa_context_get_source_info_list(ctx, source_info_cb, &sources);
    while (pa_operation_get_state(op) == PA_OPERATION_RUNNING) {
        pa_mainloop_iterate(ml, 0, nullptr);
    }
    pa_operation_unref(op);

    for (auto& [name, desc] : sources) {
        fprintf(stderr, "  %-60s  %s\n", name.c_str(), desc.c_str());
    }

    pa_context_disconnect(ctx);
    pa_context_unref(ctx);
    pa_mainloop_free(ml);
}

void AudioEngine::prepare() {
    if (pa_) return;

    pa_sample_spec spec{};
    spec.format = PA_SAMPLE_FLOAT32LE;
    spec.channels = 1;
    spec.rate = 48000;

    const char* dev = device.empty() ? nullptr : device.c_str();

    int err = 0;
    pa_ = pa_simple_new(nullptr, "speak", PA_STREAM_RECORD, dev,
                         "capture", &spec, nullptr, nullptr, &err);
    if (!pa_) {
        fprintf(stderr, "[AudioEngine] pa_simple_new failed: %s\n", pa_strerror(err));
        if (dev) fprintf(stderr, "[AudioEngine] Device was: %s\n", dev);
        fprintf(stderr, "[AudioEngine] Available sources:\n");
        list_devices();
        return;
    }

    hardware_sr_ = spec.rate;
    running_ = true;
    capture_thread_ = std::thread(&AudioEngine::capture_loop, this);
    fprintf(stderr, "[AudioEngine] Engine started (%.0f Hz, device: %s)\n",
            hardware_sr_, dev ? dev : "default");
}

void AudioEngine::start_recording() {
    if (!pa_) prepare();
    vad_.reset();
    buffer_.drain();
    collecting_ = true;
    fprintf(stderr, "[AudioEngine] Recording started\n");
}

std::vector<float> AudioEngine::stop_recording() {
    collecting_ = false;

    auto raw = buffer_.drain();
    vad_.reset();

    fprintf(stderr, "\n[AudioEngine] Stopped. Raw samples: %zu (%.1fs), mic level: %.4f\n",
            raw.size(), static_cast<double>(raw.size()) / hardware_sr_,
            audio_level_.load(std::memory_order_relaxed));

    if (raw.empty()) return {};

    auto resampled = resample(raw, hardware_sr_, 16000);
    fprintf(stderr, "[AudioEngine] Resampled to %zu samples (%.1fs at 16kHz)\n",
            resampled.size(), static_cast<double>(resampled.size()) / 16000.0);
    return resampled;
}

void AudioEngine::release() {
    running_ = false;
    collecting_ = false;
    if (capture_thread_.joinable()) capture_thread_.join();
    if (pa_) {
        pa_simple_free(pa_);
        pa_ = nullptr;
    }
}

void AudioEngine::capture_loop() {
    constexpr size_t FRAME = 4096;
    std::vector<float> buf(FRAME);
    int err = 0;
    while (running_) {
        if (pa_simple_read(pa_, buf.data(), FRAME * sizeof(float), &err) < 0) {
            fprintf(stderr, "[AudioEngine] read error: %s\n", pa_strerror(err));
            break;
        }

        float sum_sq = 0;
        for (size_t i = 0; i < FRAME; ++i) sum_sq += buf[i] * buf[i];
        float rms = std::sqrt(sum_sq / static_cast<float>(FRAME));
        audio_level_.store(std::min(1.0f, rms), std::memory_order_relaxed);

        if (!collecting_) continue;

        auto filtered = vad_.process(buf.data(), FRAME, static_cast<int>(hardware_sr_));
        if (!filtered.empty()) {
            buffer_.append(filtered.data(), filtered.size());
        }
    }
}

std::vector<float> AudioEngine::resample_public(const std::vector<float>& input) {
    return resample(input, hardware_sr_, 16000);
}

std::vector<float> AudioEngine::resample(const std::vector<float>& input, double from, double to) {
    if (from == to || input.empty()) return input;

    double ratio = from / to;
    size_t out_count = static_cast<size_t>(static_cast<double>(input.size()) / ratio);
    if (out_count == 0) return {};

    std::vector<float> output(out_count);
    for (size_t i = 0; i < out_count; ++i) {
        double src_idx = static_cast<double>(i) * ratio;
        size_t idx0 = static_cast<size_t>(src_idx);
        float frac = static_cast<float>(src_idx - static_cast<double>(idx0));
        size_t idx1 = std::min(idx0 + 1, input.size() - 1);
        output[i] = input[idx0] * (1.0f - frac) + input[idx1] * frac;
    }
    return output;
}
