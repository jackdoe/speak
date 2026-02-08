#include "model_manager.h"
#include <filesystem>
#include <algorithm>
#include <fstream>
#include <cstdlib>

namespace fs = std::filesystem;

std::string ModelNameFormatter::display_name(const std::string& filename) {
    std::string name = filename;

    auto replace = [&](const std::string& from, const std::string& to) {
        for (size_t pos = 0; (pos = name.find(from, pos)) != std::string::npos; pos += to.size())
            name.replace(pos, from.size(), to);
    };

    replace("ggml-", "");
    replace(".bin", "");
    replace("-q5_0", " (Q5)");
    replace("-q8_0", " (Q8)");
    replace("-q5_1", " (Q5.1)");

    if (name.size() >= 3 && name.substr(name.size() - 3) == ".en") {
        name = name.substr(0, name.size() - 3) + " English";
    }

    std::string result;
    bool cap_next = true;
    for (char c : name) {
        if (c == '-') {
            result += ' ';
            cap_next = true;
        } else {
            if (cap_next && c >= 'a' && c <= 'z') {
                result += static_cast<char>(c - 32);
            } else {
                result += c;
            }
            cap_next = false;
        }
    }
    return result;
}

std::string WhisperModel::name() const {
    return ModelNameFormatter::display_name(id);
}

std::string ModelManager::models_directory() {
    const char* xdg = std::getenv("XDG_DATA_HOME");
    if (xdg && xdg[0]) return std::string(xdg) + "/speak/models";
    const char* home = std::getenv("HOME");
    return std::string(home ? home : ".") + "/.local/share/speak/models";
}

static std::string config_dir() {
    const char* xdg = std::getenv("XDG_CONFIG_HOME");
    if (xdg && xdg[0]) return std::string(xdg) + "/speak";
    const char* home = std::getenv("HOME");
    return std::string(home ? home : ".") + "/.config/speak";
}

std::string ModelManager::saved_model_path() {
    return config_dir() + "/selected_model";
}

void ModelManager::save_selection(const std::string& id) {
    fs::create_directories(config_dir());
    std::ofstream(saved_model_path()) << id;
}

std::string ModelManager::load_selection() {
    std::ifstream f(saved_model_path());
    std::string id;
    std::getline(f, id);
    return id;
}

ModelManager::ModelManager() {
    scan();
}

void ModelManager::scan() {
    models_.clear();
    current_idx_ = -1;

    std::string dir = models_directory();
    fs::create_directories(dir);

    std::error_code ec;
    for (auto& entry : fs::directory_iterator(dir, ec)) {
        if (!entry.is_regular_file()) continue;
        if (entry.path().extension() != ".bin") continue;

        WhisperModel m;
        m.id = entry.path().stem().string();
        m.path = entry.path().string();
        m.size = static_cast<int64_t>(entry.file_size());
        models_.push_back(std::move(m));
    }

    std::sort(models_.begin(), models_.end(),
              [](const WhisperModel& a, const WhisperModel& b) { return a.size < b.size; });
}

std::unique_ptr<WhisperContext> ModelManager::load(const WhisperModel& model, const Settings& settings) {
    auto ctx = std::make_unique<WhisperContext>(model.path, settings);

    for (int i = 0; i < static_cast<int>(models_.size()); ++i) {
        if (models_[i].id == model.id) { current_idx_ = i; break; }
    }

    save_selection(model.id);
    return ctx;
}

std::unique_ptr<WhisperContext> ModelManager::load_saved_or_first(const Settings& settings) {
    std::string saved = load_selection();
    if (!saved.empty()) {
        for (auto& m : models_) {
            if (m.id == saved) return load(m, settings);
        }
    }
    if (models_.empty()) throw std::runtime_error("No models found");
    return load(models_.front(), settings);
}
