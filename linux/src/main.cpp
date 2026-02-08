#include "transcription_pipeline.h"
#include "hotkey_manager.h"
#include "overlay.h"
#include "control.h"
#include "text_output.h"
#include "model_downloader.h"
#include "benchmark.h"
#include <csignal>
#include <cstring>
#include <cstdlib>
#include <thread>
#include <chrono>
#include <sstream>
#include <filesystem>

namespace fs = std::filesystem;

static std::atomic<bool> g_running{true};

static void signal_handler(int) {
    g_running = false;
}

static std::string handle_command(TranscriptionPipeline& pipeline, Overlay& overlay, const std::string& cmd) {
    if (cmd == "status") {
        std::ostringstream ss;
        ss << (pipeline.is_recording() ? "recording" : pipeline.is_transcribing() ? "transcribing" : "idle");
        auto* m = pipeline.model_manager().current();
        if (m) ss << "\nmodel: " << m->name();
        ss << "\nmode: " << (pipeline.settings().transcription_mode == TranscriptionMode::continuous ? "continuous" : "buffered");
        ss << "\ntotal: " << pipeline.perf().total();
        if (pipeline.perf().total() > 0)
            ss << "\navg_rtf: " << pipeline.perf().average_rtf();
        return ss.str();
    }

    if (cmd == "stop" || cmd == "quit") {
        g_running = false;
        return "ok";
    }

    if (cmd == "models") {
        std::ostringstream ss;
        auto* cur = pipeline.model_manager().current();
        for (auto& m : pipeline.model_manager().available()) {
            if (cur && cur->id == m.id) ss << "* ";
            else ss << "  ";
            ss << m.name() << " (" << (m.size / 1000000) << " MB)\n";
        }
        return ss.str();
    }

    if (cmd.size() > 6 && cmd.substr(0, 6) == "model ") {
        std::string name = cmd.substr(6);
        for (auto& m : pipeline.model_manager().available()) {
            if (m.name() == name || m.id == name) {
                try {
                    pipeline.load_model(m);
                    return "ok: loaded " + m.name();
                } catch (const std::exception& e) {
                    return std::string("error: ") + e.what();
                }
            }
        }
        return "error: model not found";
    }

    if (cmd == "continuous on") {
        pipeline.settings().transcription_mode = TranscriptionMode::continuous;
        pipeline.settings().save();
        return "ok";
    }
    if (cmd == "continuous off") {
        pipeline.settings().transcription_mode = TranscriptionMode::buffered;
        pipeline.settings().save();
        return "ok";
    }

    if (cmd == "mic-warm on") {
        pipeline.settings().keep_mic_warm = true;
        pipeline.settings().save();
        pipeline.audio_engine().prepare();
        return "ok";
    }
    if (cmd == "mic-warm off") {
        pipeline.settings().keep_mic_warm = false;
        pipeline.settings().save();
        pipeline.audio_engine().release();
        return "ok";
    }

    if (cmd == "reload") {
        pipeline.model_manager().scan();
        return "ok: " + std::to_string(pipeline.model_manager().available().size()) + " models";
    }

    return "error: unknown command\ncommands: status, stop, models, model <name>, continuous on|off, mic-warm on|off, reload";
}

static void print_usage() {
    fprintf(stderr,
        "speak — push-to-talk transcription\n"
        "\n"
        "run:\n"
        "  speak -model <path>          model file (.bin)\n"
        "  speak -continuous             continuous transcription mode\n"
        "  speak -warm                   keep mic open between recordings\n"
        "  speak -type                   output via simulated typing (default: paste)\n"
        "  speak -no-vad                 disable voice activity detection\n"
        "  speak -device <name>          PulseAudio source (see: speak --devices)\n"
        "  speak -gpu / -no-gpu          force GPU on/off\n"
        "  speak -threads <n>            inference threads\n"
        "  speak -lang <code>            language code (default: en)\n"
        "\n"
        "models:\n"
        "  speak --remote-models         list downloadable models\n"
        "  speak --download <name>       download model to %s\n"
        "\n"
        "daemon control:\n"
        "  speak status                  query running instance\n"
        "  speak stop                    stop running instance\n"
        "  speak models                  list local models\n"
        "  speak model <name>            switch model\n"
        "  speak continuous on|off       toggle mode\n"
        "\n"
        "benchmark:\n"
        "  speak --benchmark <model>     run benchmark\n",
        ModelManager::models_directory().c_str()
    );
}

static int cmd_remote_models() {
    auto models = ModelDownloader::fallback_models();
    std::string dir = ModelManager::models_directory();

    for (auto& m : models) {
        bool local = fs::exists(dir + "/" + m.filename);
        printf("  %s %-36s %4lld MB  %s\n",
               local ? "*" : " ",
               m.filename.c_str(),
               static_cast<long long>(m.size / 1000000),
               m.url.c_str());
    }
    return 0;
}

static int cmd_download(const char* name) {
    auto models = ModelDownloader::fallback_models();
    std::string target = name;

    if (target.find(".bin") == std::string::npos) target += ".bin";
    if (target.find("ggml-") != 0) target = "ggml-" + target;

    const RemoteModel* found = nullptr;
    for (auto& m : models) {
        if (m.filename == target) { found = &m; break; }
    }

    if (!found) {
        fprintf(stderr, "Unknown model: %s\nAvailable:\n", name);
        for (auto& m : models) fprintf(stderr, "  %s\n", m.filename.c_str());
        return 1;
    }

    std::string dest = ModelManager::models_directory() + "/" + found->filename;
    if (fs::exists(dest)) {
        printf("Already downloaded: %s\n", dest.c_str());
        return 0;
    }

    printf("Downloading %s (%lld MB)...\n", found->filename.c_str(),
           static_cast<long long>(found->size / 1000000));

    int last_pct = -1;
    bool ok = ModelDownloader::download(found->url, dest, [&](double frac) {
        int pct = static_cast<int>(frac * 100);
        if (pct != last_pct) {
            last_pct = pct;
            printf("\r  %3d%%", pct);
            fflush(stdout);
        }
    });

    if (ok) {
        printf("\r  done: %s\n", dest.c_str());
        return 0;
    } else {
        printf("\r  failed\n");
        return 1;
    }
}

static void run_daemon(TranscriptionPipeline& pipeline, const std::string& model_path) {
    HotkeyManager hotkey;
    Overlay overlay;
    ControlServer control;

    pipeline.on_transcription_start = [&]() {
        overlay.set_state(Overlay::State::transcribing);
    };
    pipeline.on_transcription_end = [&]() {
        overlay.set_state(Overlay::State::hidden);
    };

    control.on_command = [&](const std::string& cmd) {
        return handle_command(pipeline, overlay, cmd);
    };
    control.start();

    pipeline.apply_vad_settings();

    hotkey.set_keysyms(pipeline.settings().hotkey_keysym, pipeline.settings().send_hotkey_keysym);

    hotkey.on_key_down = [&](bool) {
        pipeline.start_recording();
        overlay.set_state(Overlay::State::recording);
    };

    hotkey.on_key_up = [&](bool is_send) {
        int delay_ms = pipeline.settings().release_delay_ms;
        std::thread([&pipeline, &overlay, is_send, delay_ms]() {
            std::this_thread::sleep_for(std::chrono::milliseconds(delay_ms));
            overlay.set_state(Overlay::State::transcribing);

            pipeline.stop_recording_and_transcribe();

            if (is_send && pipeline.did_output_text()) {
                int rd = pipeline.settings().send_return_delay_ms;
                std::this_thread::sleep_for(std::chrono::milliseconds(rd));
                TextOutput::press_return();
            }

            overlay.set_state(Overlay::State::hidden);
        }).detach();
    };

    if (!hotkey.start()) {
        fprintf(stderr, "[main] Hotkey manager failed — is X11 running?\n");
        return;
    }

    if (pipeline.settings().keep_mic_warm) {
        pipeline.audio_engine().prepare();
    }

    if (!model_path.empty()) {
        if (!fs::exists(model_path)) {
            fprintf(stderr, "[main] Model not found: %s\n", model_path.c_str());
            fprintf(stderr, "[main] Download one with: speak --download tiny.en\n");
            hotkey.stop();
            control.stop();
            return;
        }
        WhisperModel m;
        m.id = fs::path(model_path).stem().string();
        m.path = model_path;
        m.size = static_cast<int64_t>(fs::file_size(model_path));
        try {
            pipeline.load_model(m);
        } catch (const std::exception& e) {
            fprintf(stderr, "[main] Failed to load model: %s\n", e.what());
            hotkey.stop();
            control.stop();
            return;
        }
    } else {
        pipeline.model_manager().scan();
        if (!pipeline.model_manager().available().empty()) {
            try {
                pipeline.load_first_available();
                fprintf(stderr, "[main] Auto-loaded model\n");
            } catch (const std::exception& e) {
                fprintf(stderr, "[main] No model auto-loaded: %s\n", e.what());
            }
        } else {
            fprintf(stderr, "[main] No models found in %s\n", ModelManager::models_directory().c_str());
            fprintf(stderr, "[main] Download one with: speak --download tiny.en\n");
            hotkey.stop();
            control.stop();
            return;
        }
    }

    fprintf(stderr, "[main] Ready — F12 hold-to-talk, F11 hold-to-talk+return, Ctrl+C to quit\n");

    while (g_running) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    hotkey.stop();
    control.stop();
    pipeline.shutdown();
    fprintf(stderr, "[main] Shutdown complete\n");
}

int main(int argc, char* argv[]) {
    if (argc >= 3 && std::strcmp(argv[1], "--benchmark") == 0) {
        run_benchmark(argv[2]);
        return 0;
    }

    if (argc >= 2 && std::strcmp(argv[1], "--remote-models") == 0) {
        return cmd_remote_models();
    }

    if (argc >= 2 && (std::strcmp(argv[1], "--devices") == 0 || std::strcmp(argv[1], "-devices") == 0)) {
        AudioEngine::list_devices();
        return 0;
    }

    if (argc >= 3 && std::strcmp(argv[1], "--download") == 0) {
        return cmd_download(argv[2]);
    }

    if (argc >= 2 && (std::strcmp(argv[1], "--help") == 0 || std::strcmp(argv[1], "-h") == 0)) {
        print_usage();
        return 0;
    }

    bool has_flags = false;
    for (int i = 1; i < argc; ++i) {
        if (argv[i][0] == '-') { has_flags = true; break; }
    }

    if (argc >= 2 && !has_flags) {
        std::string cmd;
        for (int i = 1; i < argc; ++i) {
            if (i > 1) cmd += ' ';
            cmd += argv[i];
        }
        auto response = ControlServer::send_command(cmd);
        printf("%s\n", response.c_str());
        return response.substr(0, 5) == "error" ? 1 : 0;
    }

    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

    std::string model_path;
    TranscriptionPipeline pipeline;

    for (int i = 1; i < argc; ++i) {
        if ((std::strcmp(argv[i], "-model") == 0 || std::strcmp(argv[i], "--model") == 0) && i + 1 < argc) {
            model_path = argv[++i];
        } else if (std::strcmp(argv[i], "-continuous") == 0 || std::strcmp(argv[i], "--continuous") == 0) {
            pipeline.settings().transcription_mode = TranscriptionMode::continuous;
        } else if (std::strcmp(argv[i], "-buffered") == 0 || std::strcmp(argv[i], "--buffered") == 0) {
            pipeline.settings().transcription_mode = TranscriptionMode::buffered;
        } else if (std::strcmp(argv[i], "-warm") == 0 || std::strcmp(argv[i], "--warm") == 0) {
            pipeline.settings().keep_mic_warm = true;
        } else if (std::strcmp(argv[i], "-no-warm") == 0 || std::strcmp(argv[i], "--no-warm") == 0) {
            pipeline.settings().keep_mic_warm = false;
        } else if (std::strcmp(argv[i], "-type") == 0 || std::strcmp(argv[i], "--type") == 0) {
            pipeline.settings().output_mode = OutputMode::type;
        } else if (std::strcmp(argv[i], "-paste") == 0 || std::strcmp(argv[i], "--paste") == 0) {
            pipeline.settings().output_mode = OutputMode::paste;
        } else if (std::strcmp(argv[i], "-gpu") == 0 || std::strcmp(argv[i], "--gpu") == 0) {
            pipeline.settings().use_gpu = true;
        } else if (std::strcmp(argv[i], "-no-gpu") == 0 || std::strcmp(argv[i], "--no-gpu") == 0) {
            pipeline.settings().use_gpu = false;
        } else if ((std::strcmp(argv[i], "-threads") == 0 || std::strcmp(argv[i], "--threads") == 0) && i + 1 < argc) {
            pipeline.settings().thread_count = std::atoi(argv[++i]);
        } else if ((std::strcmp(argv[i], "-lang") == 0 || std::strcmp(argv[i], "--lang") == 0) && i + 1 < argc) {
            pipeline.settings().language = argv[++i];
        } else if (std::strcmp(argv[i], "-no-vad") == 0 || std::strcmp(argv[i], "--no-vad") == 0) {
            pipeline.settings().vad_enabled = false;
        } else if ((std::strcmp(argv[i], "-device") == 0 || std::strcmp(argv[i], "--device") == 0) && i + 1 < argc) {
            pipeline.audio_engine().device = argv[++i];
        }
    }

    run_daemon(pipeline, model_path);
    return 0;
}
