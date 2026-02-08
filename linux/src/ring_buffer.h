#pragma once

#include <vector>
#include <mutex>

class RingBuffer {
    std::vector<float> samples_;
    mutable std::mutex mu_;

public:
    void append(const float* data, size_t count) {
        std::lock_guard<std::mutex> lk(mu_);
        samples_.insert(samples_.end(), data, data + count);
    }

    std::vector<float> drain() {
        std::lock_guard<std::mutex> lk(mu_);
        std::vector<float> out;
        out.swap(samples_);
        samples_.reserve(out.capacity());
        return out;
    }

    double duration() const {
        std::lock_guard<std::mutex> lk(mu_);
        return static_cast<double>(samples_.size()) / 16000.0;
    }

    size_t count() const {
        std::lock_guard<std::mutex> lk(mu_);
        return samples_.size();
    }
};
