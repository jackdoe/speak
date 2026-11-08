#include "keyboard.h"
#include "microphone.h"
#include "recognizer.h"
#include "status.h"
#include "wayland.h"

#include <signal.h>
#include <sys/signalfd.h>
#include <unistd.h>

#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <mutex>
#include <optional>
#include <thread>

static constexpr int64_t preroll = Microphone::rate / 4;
static constexpr int64_t tail = Microphone::rate * 3 / 20;

struct Options {
    std::string model;
    std::string device;
    bool gpu = true;
    std::string file;
    bool devices = false;
    bool waybar = false;
};

static std::string default_model() {
    const char* data = std::getenv("XDG_DATA_HOME");
    std::string base = data && *data ? data : std::string(std::getenv("HOME")) + "/.local/share";
    return base + "/speak/parakeet-tdt-0.6b-v2";
}

static void usage() {
    fprintf(stderr,
            "speak — hold-to-talk dictation for Hyprland\n\n"
            "  speak [--model DIR] [--device SOURCE] [--cpu]   run\n"
            "  speak FILE.wav [--model DIR] [--cpu]            transcribe a file\n"
            "  speak --devices                                  list audio sources\n"
            "  speak --waybar                                   stream status for a waybar custom module\n\n"
            "hyprland.conf:\n"
            "  exec-once = speak\n"
            "  bind = , Page_Down, global, speak:talk\n"
            "  bind = SHIFT, Page_Down, global, speak:send\n\n"
            "model: %s\n",
            default_model().c_str());
}

static std::optional<Options> parse(int argc, char** argv) {
    Options o;
    o.model = default_model();
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--model" && i + 1 < argc) o.model = argv[++i];
        else if (a == "--device" && i + 1 < argc) o.device = argv[++i];
        else if (a == "--cpu") o.gpu = false;
        else if (a == "--devices") o.devices = true;
        else if (a == "--waybar") o.waybar = true;
        else if (!a.starts_with("-") && o.file.empty()) o.file = a;
        else return std::nullopt;
    }
    return o;
}

static std::u32string utf32(const std::string& s) {
    std::u32string out;
    for (size_t i = 0; i < s.size();) {
        unsigned char c = s[i];
        int n = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
        char32_t cp = n == 1 ? c : c & (0x7F >> n);
        for (int k = 1; k < n && i + k < s.size(); ++k) cp = (cp << 6) | (s[i + k] & 0x3F);
        out.push_back(cp);
        i += n;
    }
    return out;
}

static double ms_since(std::chrono::steady_clock::time_point t) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t).count();
}

static std::vector<float> read_wav(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    char riff[12];
    if (!in.read(riff, 12) || std::string(riff, 4) != "RIFF" || std::string(riff + 8, 4) != "WAVE")
        throw std::runtime_error(path + ": not a wav file");
    uint16_t format = 0, channels = 0, bits = 0;
    uint32_t rate = 0;
    for (;;) {
        char id[4];
        uint32_t size;
        if (!in.read(id, 4) || !in.read(reinterpret_cast<char*>(&size), 4)) throw std::runtime_error(path + ": no data");
        std::string chunk(id, 4);
        if (chunk == "fmt ") {
            std::vector<char> fmt(size);
            in.read(fmt.data(), size);
            std::memcpy(&format, fmt.data(), 2);
            std::memcpy(&channels, fmt.data() + 2, 2);
            std::memcpy(&rate, fmt.data() + 4, 4);
            std::memcpy(&bits, fmt.data() + 14, 2);
        } else if (chunk == "data") {
            if (format != 1 || channels != 1 || bits != 16 || rate != Microphone::rate)
                throw std::runtime_error(path + ": need 16-bit mono PCM at 16 kHz");
            std::vector<int16_t> pcm(size / 2);
            in.read(reinterpret_cast<char*>(pcm.data()), std::streamsize(pcm.size() * 2));
            std::vector<float> samples(pcm.size());
            for (size_t i = 0; i < pcm.size(); ++i) samples[i] = pcm[i] / 32768.0f;
            return samples;
        } else {
            in.seekg(size + (size & 1), std::ios::cur);
        }
    }
}

static int transcribe_file(const Options& o) {
    std::vector<float> samples = read_wav(o.file);
    Recognizer recognizer(o.model, o.gpu);
    auto t = std::chrono::steady_clock::now();
    std::string text = recognizer.transcribe(samples);
    fprintf(stderr, "%.1fs audio in %.0f ms\n", double(samples.size()) / Microphone::rate, ms_since(t));
    printf("%s\n", text.c_str());
    return 0;
}

struct Job {
    int64_t from, to;
    bool enter;
};

static int run(const Options& o) {
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGINT);
    sigaddset(&mask, SIGTERM);
    pthread_sigmask(SIG_BLOCK, &mask, nullptr);
    int stop_fd = signalfd(-1, &mask, SFD_CLOEXEC);

    Wayland wayland;
    Status status;
    Keyboard keyboard(wayland);
    Microphone mic(o.device);
    Recognizer recognizer(o.model, o.gpu);

    std::mutex mu;
    std::condition_variable cv;
    std::deque<Job> jobs;
    bool stopping = false;

    int64_t start = -1;
    bool start_enter = false;
    int pending = 0;

    auto settle = [&] {
        status.set(start >= 0 ? Status::recording : pending ? Status::transcribing : Status::idle);
    };

    std::thread worker([&] {
        for (;;) {
            Job job;
            {
                std::unique_lock lk(mu);
                cv.wait(lk, [&] { return stopping || !jobs.empty(); });
                if (stopping) return;
                job = jobs.front();
                jobs.pop_front();
            }
            auto samples = mic.slice(job.from, job.to);
            auto t = std::chrono::steady_clock::now();
            std::string text = recognizer.transcribe(samples);
            float peak = 0;
            for (float x : samples) peak = std::max(peak, std::abs(x));
            char summary[96];
            snprintf(summary, sizeof(summary), "%.1fs audio, peak %.3f, in %.0f ms", double(samples.size()) / Microphone::rate, peak, ms_since(t));
            fprintf(stderr, "%s, %zu chars\n", summary, text.size());
            status.set_last(std::string(summary) + (text.empty() ? ", nothing heard" : ""));
            wayland.post([&, text, enter = job.enter] {
                if (!text.empty()) keyboard.type(utf32(text + (enter ? "\n" : " ")));
                --pending;
                settle();
            });
        }
    });

    auto hold = [&](bool enter) {
        return [&, enter](bool pressed) {
            fprintf(stderr, "%s %s\n", enter ? "send" : "talk", pressed ? "pressed" : "released");
            if (pressed && start < 0) {
                start = std::max<int64_t>(0, mic.now() - preroll);
                start_enter = enter;
            } else if (!pressed && start >= 0 && start_enter == enter) {
                {
                    std::lock_guard lk(mu);
                    jobs.push_back({start, mic.now() + tail, enter});
                }
                cv.notify_one();
                start = -1;
                ++pending;
            }
            settle();
        };
    };
    wayland.shortcut("talk", "Hold to dictate", hold(false));
    wayland.shortcut("send", "Hold to dictate, then press Enter", hold(true));

    struct Finally {
        std::function<void()> f;
        ~Finally() { f(); }
    } finally{[&] {
        {
            std::lock_guard lk(mu);
            stopping = true;
        }
        cv.notify_one();
        worker.join();
        close(stop_fd);
    }};

    fprintf(stderr, "ready\n");
    wayland.run(stop_fd);
    return 0;
}

int main(int argc, char** argv) {
    auto o = parse(argc, argv);
    if (!o) {
        usage();
        return 2;
    }
    if (o->devices) {
        Microphone::list_devices();
        return 0;
    }
    try {
        if (o->waybar) Status::follow();
        return o->file.empty() ? run(*o) : transcribe_file(*o);
    } catch (const std::exception& e) {
        fprintf(stderr, "speak: %s\n", e.what());
        return 1;
    }
}
