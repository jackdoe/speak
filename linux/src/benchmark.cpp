#include "benchmark.h"
#include "performance_monitor.h"
#include "whisper.h"
#include <vector>
#include <cstdio>
#include <cmath>
#include <chrono>
#include <algorithm>
#include <thread>

static std::vector<float> generate_tone(double duration_s, int sr = 16000, float base_freq = 440.0f) {
    int count = static_cast<int>(duration_s * sr);
    std::vector<float> samples(count);
    float fsr = static_cast<float>(sr);

    struct H { float freq, amp; };
    H harmonics[] = {
        {base_freq, 0.3f}, {base_freq * 2.0f, 0.15f},
        {base_freq * 3.0f, 0.08f}, {base_freq * 0.5f, 0.1f}
    };

    for (int i = 0; i < count; ++i) {
        float t = static_cast<float>(i) / fsr;
        float v = 0;
        for (auto& h : harmonics) v += h.amp * std::sin(2.0f * 3.14159265f * h.freq * t);
        float env = 0.8f + 0.2f * std::sin(2.0f * 3.14159265f * 3.0f * t);
        samples[i] = v * env;
    }
    return samples;
}

static std::vector<float> generate_with_gap(double total, double gap_start, double gap_dur, int sr = 16000) {
    auto samples = generate_tone(total, sr);
    int gs = static_cast<int>(gap_start * sr);
    int ge = std::min(static_cast<int>((gap_start + gap_dur) * sr), static_cast<int>(samples.size()));
    for (int i = gs; i < ge; ++i) samples[i] = 0;
    return samples;
}

void run_benchmark(const std::string& model_path) {
    printf("SpeakBenchmark\n==============\nModel: %s\n\n", model_path.c_str());

    printf("Loading model...\n");
    auto load_start = std::chrono::steady_clock::now();

    auto cparams = whisper_context_default_params();
    cparams.use_gpu = true;

    auto* ctx = whisper_init_from_file_with_params(model_path.c_str(), cparams);
    if (!ctx) { printf("Error: Failed to load model\n"); return; }

    double load_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - load_start).count();
    printf("Model loaded in %.0f ms\n\n", load_ms);

    struct Scenario { const char* name; std::vector<float> samples; };
    Scenario scenarios[] = {
        {"Short utterance (2s)",       generate_tone(2.0)},
        {"Medium utterance (10s)",     generate_tone(10.0)},
        {"Long recording (60s)",       generate_tone(60.0)},
        {"Silence gap (5s, 2s gap)",   generate_with_gap(5.0, 1.5, 2.0)},
    };

    printf("%-28s  %8s  %10s  %7s  %4s  %8s\n", "Scenario", "Audio", "Transc.", "RTF", "Seg", "Mem MB");
    printf("------------------------------------------------------------------------\n");

    int threads = std::max(1, std::min(8, static_cast<int>(std::thread::hardware_concurrency()) - 2));

    for (auto& sc : scenarios) {
        double audio_ms = static_cast<double>(sc.samples.size()) / 16000.0 * 1000.0;
        double mem_before = PerformanceMonitor::resident_memory_mb();

        auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.n_threads = threads;
        params.no_context = true;
        params.print_special = false;
        params.print_progress = false;
        params.print_realtime = false;
        params.print_timestamps = false;
        params.language = "en";

        auto start = std::chrono::steady_clock::now();
        int res = whisper_full(ctx, params, sc.samples.data(), static_cast<int>(sc.samples.size()));
        double elapsed = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - start).count();

        double mem_after = PerformanceMonitor::resident_memory_mb();
        double rtf = audio_ms > 0 ? elapsed / audio_ms : 0;

        int n_seg = 0;
        std::string text;
        if (res == 0) {
            n_seg = whisper_full_n_segments(ctx);
            for (int i = 0; i < n_seg; ++i) {
                const char* s = whisper_full_get_segment_text(ctx, i);
                if (s) text += s;
            }
        }

        char audio_str[32], transc_str[32];
        if (audio_ms < 1000) std::snprintf(audio_str, sizeof(audio_str), "%.0f ms", audio_ms);
        else std::snprintf(audio_str, sizeof(audio_str), "%.1f s", audio_ms / 1000.0);

        if (elapsed < 1000) std::snprintf(transc_str, sizeof(transc_str), "%.0f ms", elapsed);
        else std::snprintf(transc_str, sizeof(transc_str), "%.2f s", elapsed / 1000.0);

        printf("%-28s  %8s  %10s  %6.3fx  %4d  %7.1f\n",
               sc.name, audio_str, transc_str, rtf, n_seg, mem_after - mem_before);

        if (!text.empty()) {
            if (text.size() > 80) text = text.substr(0, 80) + "...";
            printf("  -> %s\n", text.c_str());
        }
    }

    whisper_free(ctx);
    printf("\nDone.\n");
}
