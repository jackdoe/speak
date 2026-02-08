#pragma once

#include <string>
#include <vector>

struct TranscriptionSegment {
    std::string text;
    int64_t start_time;
    int64_t end_time;
};

struct TranscriptionResult {
    std::vector<TranscriptionSegment> segments;
    double audio_duration_ms;
    double transcription_time_ms;
    std::string model_name;

    std::string full_text() const {
        std::string out;
        for (auto& s : segments) out += s.text;
        return out;
    }

    double real_time_factor() const {
        if (audio_duration_ms <= 0) return 0;
        return transcription_time_ms / audio_duration_ms;
    }
};
