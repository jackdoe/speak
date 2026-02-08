#pragma once

#include "transcription_result.h"
#include <cstdio>
#include <fstream>
#include <string>

class PerformanceMonitor {
    TranscriptionResult last_;
    int total_ = 0;
    double rtf_sum_ = 0;

public:
    void record(const TranscriptionResult& r) {
        last_ = r;
        ++total_;
        rtf_sum_ += r.real_time_factor();
    }

    double average_rtf() const { return total_ > 0 ? rtf_sum_ / total_ : 0; }
    int total() const { return total_; }
    const TranscriptionResult& last() const { return last_; }

    static double resident_memory_mb() {
        std::ifstream f("/proc/self/status");
        std::string line;
        while (std::getline(f, line)) {
            if (line.compare(0, 6, "VmRSS:") == 0) {
                long kb = 0;
                std::sscanf(line.c_str(), "VmRSS: %ld", &kb);
                return static_cast<double>(kb) / 1024.0;
            }
        }
        return 0;
    }
};
