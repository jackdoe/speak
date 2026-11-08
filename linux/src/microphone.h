#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct pa_simple;

class Microphone {
public:
    static constexpr int rate = 16000;

    explicit Microphone(const std::string& device);
    ~Microphone();

    Microphone(const Microphone&) = delete;
    Microphone& operator=(const Microphone&) = delete;

    int64_t now() const;
    std::vector<float> slice(int64_t from, int64_t to);

    static void list_devices();

private:
    static constexpr int64_t capacity = int64_t(rate) * 600;

    pa_simple* stream_;
    std::vector<float> ring_;
    int64_t written_ = 0;
    mutable std::mutex mu_;
    std::condition_variable cv_;
    std::atomic<bool> running_{true};
    std::thread thread_;

    void capture();
};
