#pragma once

#include <string>
#include <vector>
#include <functional>

struct RemoteModel {
    std::string filename;
    int64_t size;
    std::string url;
};

class ModelDownloader {
public:
    static std::vector<RemoteModel> fallback_models();
    static bool download(const std::string& url, const std::string& dest_path,
                         std::function<void(double)> progress = nullptr);

private:
    static constexpr const char* HF_RESOLVE_BASE = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main";
};
