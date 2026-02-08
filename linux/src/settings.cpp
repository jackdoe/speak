#include "settings.h"
#include <nlohmann/json.hpp>
#include <fstream>
#include <cstdlib>
#include <sys/stat.h>

using json = nlohmann::json;

static std::string config_dir() {
    const char* xdg = std::getenv("XDG_CONFIG_HOME");
    if (xdg && xdg[0]) return std::string(xdg) + "/speak";
    const char* home = std::getenv("HOME");
    return std::string(home ? home : ".") + "/.config/speak";
}

std::string Settings::config_path() {
    return config_dir() + "/settings.json";
}

static void ensure_dir(const std::string& dir) {
    mkdir(dir.c_str(), 0755);
}

Settings Settings::load() {
    Settings s;
    std::ifstream f(config_path());
    if (!f) return s;

    json j;
    try { f >> j; } catch (...) { return s; }

    auto get = [&](const char* k, auto& v) {
        if (j.contains(k)) j.at(k).get_to(v);
    };

    std::string strat;
    get("strategy", strat);
    if (strat == "beam_search") s.strategy = SamplingStrategy::beam_search;

    get("temperature", s.temperature);
    get("best_of", s.best_of);
    get("beam_size", s.beam_size);
    get("language", s.language);
    get("translate", s.translate);
    get("thread_count", s.thread_count);
    get("use_gpu", s.use_gpu);
    get("flash_attention", s.flash_attention);
    get("no_context", s.no_context);
    get("single_segment", s.single_segment);
    get("no_timestamps", s.no_timestamps);
    get("token_timestamps", s.token_timestamps);
    get("suppress_blank", s.suppress_blank);
    get("suppress_non_speech_tokens", s.suppress_non_speech_tokens);
    get("initial_prompt", s.initial_prompt);
    get("entropy_threshold", s.entropy_threshold);
    get("logprob_threshold", s.logprob_threshold);
    get("no_speech_threshold", s.no_speech_threshold);
    get("vad_enabled", s.vad_enabled);
    get("vad_speech_threshold", s.vad_speech_threshold);
    get("vad_silence_threshold", s.vad_silence_threshold);
    get("vad_min_speech_ms", s.vad_min_speech_ms);
    get("vad_min_silence_ms", s.vad_min_silence_ms);
    get("vad_pre_padding_ms", s.vad_pre_padding_ms);
    get("vad_post_padding_ms", s.vad_post_padding_ms);

    std::string mode;
    get("output_mode", mode);
    if (mode == "type") s.output_mode = OutputMode::type;

    get("type_speed_ms", s.type_speed_ms);
    get("restore_clipboard", s.restore_clipboard);
    get("send_return_delay_ms", s.send_return_delay_ms);
    get("hotkey_keysym", s.hotkey_keysym);
    get("send_hotkey_keysym", s.send_hotkey_keysym);
    get("keep_mic_warm", s.keep_mic_warm);

    std::string tmode;
    get("transcription_mode", tmode);
    if (tmode == "buffered") s.transcription_mode = TranscriptionMode::buffered;

    get("release_delay_ms", s.release_delay_ms);
    get("launch_at_login", s.launch_at_login);

    return s;
}

void Settings::save() const {
    ensure_dir(config_dir());

    json j;
    j["strategy"] = (strategy == SamplingStrategy::beam_search) ? "beam_search" : "greedy";
    j["temperature"] = temperature;
    j["best_of"] = best_of;
    j["beam_size"] = beam_size;
    j["language"] = language;
    j["translate"] = translate;
    j["thread_count"] = thread_count;
    j["use_gpu"] = use_gpu;
    j["flash_attention"] = flash_attention;
    j["no_context"] = no_context;
    j["single_segment"] = single_segment;
    j["no_timestamps"] = no_timestamps;
    j["token_timestamps"] = token_timestamps;
    j["suppress_blank"] = suppress_blank;
    j["suppress_non_speech_tokens"] = suppress_non_speech_tokens;
    j["initial_prompt"] = initial_prompt;
    j["entropy_threshold"] = entropy_threshold;
    j["logprob_threshold"] = logprob_threshold;
    j["no_speech_threshold"] = no_speech_threshold;
    j["vad_enabled"] = vad_enabled;
    j["vad_speech_threshold"] = vad_speech_threshold;
    j["vad_silence_threshold"] = vad_silence_threshold;
    j["vad_min_speech_ms"] = vad_min_speech_ms;
    j["vad_min_silence_ms"] = vad_min_silence_ms;
    j["vad_pre_padding_ms"] = vad_pre_padding_ms;
    j["vad_post_padding_ms"] = vad_post_padding_ms;
    j["output_mode"] = (output_mode == OutputMode::type) ? "type" : "paste";
    j["type_speed_ms"] = type_speed_ms;
    j["restore_clipboard"] = restore_clipboard;
    j["send_return_delay_ms"] = send_return_delay_ms;
    j["hotkey_keysym"] = hotkey_keysym;
    j["send_hotkey_keysym"] = send_hotkey_keysym;
    j["keep_mic_warm"] = keep_mic_warm;
    j["transcription_mode"] = (transcription_mode == TranscriptionMode::buffered) ? "buffered" : "continuous";
    j["release_delay_ms"] = release_delay_ms;
    j["launch_at_login"] = launch_at_login;

    std::ofstream out(config_path());
    out << j.dump(2) << '\n';
}
