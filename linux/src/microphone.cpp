#include "microphone.h"

#include <pulse/error.h>
#include <pulse/pulseaudio.h>
#include <pulse/simple.h>

#include <algorithm>
#include <cstdio>
#include <stdexcept>

Microphone::Microphone(const std::string& device) : ring_(capacity) {
    pa_sample_spec spec{PA_SAMPLE_FLOAT32LE, rate, 1};
    pa_buffer_attr attr{};
    attr.maxlength = UINT32_MAX;
    attr.fragsize = rate / 100 * sizeof(float);
    int err = 0;
    stream_ = pa_simple_new(nullptr, "speak", PA_STREAM_RECORD, device.empty() ? nullptr : device.c_str(),
                            "dictation", &spec, nullptr, &attr, &err);
    if (!stream_) throw std::runtime_error(std::string("microphone: ") + pa_strerror(err));
    thread_ = std::thread(&Microphone::capture, this);
}

Microphone::~Microphone() {
    running_ = false;
    thread_.join();
    pa_simple_free(stream_);
}

int64_t Microphone::now() const {
    std::lock_guard lk(mu_);
    return written_;
}

std::vector<float> Microphone::slice(int64_t from, int64_t to) {
    std::unique_lock lk(mu_);
    cv_.wait(lk, [&] { return written_ >= to || !running_; });
    to = std::min(to, written_);
    from = std::clamp(from, std::max<int64_t>(0, written_ - capacity), to);
    std::vector<float> out;
    out.reserve(size_t(to - from));
    for (int64_t i = from; i < to; ++i) out.push_back(ring_[size_t(i % capacity)]);
    return out;
}

void Microphone::capture() {
    std::vector<float> chunk(rate / 100);
    int err = 0;
    while (running_) {
        if (pa_simple_read(stream_, chunk.data(), chunk.size() * sizeof(float), &err) < 0) {
            fprintf(stderr, "microphone: %s\n", pa_strerror(err));
            running_ = false;
            break;
        }
        std::lock_guard lk(mu_);
        for (float s : chunk) ring_[size_t(written_++ % capacity)] = s;
        cv_.notify_all();
    }
    cv_.notify_all();
}

void Microphone::list_devices() {
    pa_mainloop* loop = pa_mainloop_new();
    pa_context* ctx = pa_context_new(pa_mainloop_get_api(loop), "speak");
    pa_context_connect(ctx, nullptr, PA_CONTEXT_NOFLAGS, nullptr);
    while (pa_context_get_state(ctx) != PA_CONTEXT_READY) {
        if (!PA_CONTEXT_IS_GOOD(pa_context_get_state(ctx))) {
            fprintf(stderr, "cannot connect to audio server\n");
            return;
        }
        pa_mainloop_iterate(loop, 1, nullptr);
    }
    auto print = [](pa_context*, const pa_source_info* info, int eol, void*) {
        if (!eol && info) printf("%-64s %s\n", info->name, info->description);
    };
    pa_operation* op = pa_context_get_source_info_list(ctx, print, nullptr);
    while (pa_operation_get_state(op) == PA_OPERATION_RUNNING) pa_mainloop_iterate(loop, 1, nullptr);
    pa_operation_unref(op);
    pa_context_disconnect(ctx);
    pa_context_unref(ctx);
    pa_mainloop_free(loop);
}
