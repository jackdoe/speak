#pragma once

#include "whisper_context.h"
#include "settings.h"
#include <string>
#include <vector>
#include <memory>

struct WhisperModel {
    std::string id;
    std::string path;
    int64_t size;

    std::string name() const;
    bool is_english_only() const { return id.find(".en") != std::string::npos; }
};

class ModelManager {
public:
    ModelManager();

    void scan();
    const std::vector<WhisperModel>& available() const { return models_; }
    const WhisperModel* current() const { return current_idx_ >= 0 ? &models_[current_idx_] : nullptr; }

    std::unique_ptr<WhisperContext> load(const WhisperModel& model, const Settings& settings);
    std::unique_ptr<WhisperContext> load_saved_or_first(const Settings& settings);

    static std::string models_directory();

private:
    std::vector<WhisperModel> models_;
    int current_idx_ = -1;

    static std::string saved_model_path();
    void save_selection(const std::string& id);
    std::string load_selection();
};

namespace ModelNameFormatter {
    std::string display_name(const std::string& filename);
}
