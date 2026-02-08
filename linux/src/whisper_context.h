#pragma once

#include "transcription_result.h"
#include "settings.h"
#include <string>
#include <mutex>

struct whisper_context;

class WhisperContext {
public:
    WhisperContext(const std::string& model_path, const Settings& settings);
    ~WhisperContext();

    WhisperContext(const WhisperContext&) = delete;
    WhisperContext& operator=(const WhisperContext&) = delete;

    void warmup();
    TranscriptionResult transcribe(const std::vector<float>& samples, const std::string* context_prompt = nullptr);

private:
    whisper_context* ctx_;
    Settings settings_;
    std::string model_name_;
    std::mutex mu_;
};
