#include "model_downloader.h"
#include <curl/curl.h>
#include <cstdio>
#include <filesystem>

namespace fs = std::filesystem;

std::vector<RemoteModel> ModelDownloader::fallback_models() {
    return {
        {"ggml-tiny.en.bin",             75'000'000, std::string(HF_RESOLVE_BASE) + "/ggml-tiny.en.bin"},
        {"ggml-tiny.bin",                75'000'000, std::string(HF_RESOLVE_BASE) + "/ggml-tiny.bin"},
        {"ggml-base.en.bin",            142'000'000, std::string(HF_RESOLVE_BASE) + "/ggml-base.en.bin"},
        {"ggml-base.bin",               142'000'000, std::string(HF_RESOLVE_BASE) + "/ggml-base.bin"},
        {"ggml-small.en.bin",           466'000'000, std::string(HF_RESOLVE_BASE) + "/ggml-small.en.bin"},
        {"ggml-small.bin",              466'000'000, std::string(HF_RESOLVE_BASE) + "/ggml-small.bin"},
        {"ggml-medium.en.bin",        1'500'000'000, std::string(HF_RESOLVE_BASE) + "/ggml-medium.en.bin"},
        {"ggml-medium.bin",           1'500'000'000, std::string(HF_RESOLVE_BASE) + "/ggml-medium.bin"},
        {"ggml-large-v3.bin",         2'900'000'000, std::string(HF_RESOLVE_BASE) + "/ggml-large-v3.bin"},
        {"ggml-large-v3-turbo.bin",     800'000'000, std::string(HF_RESOLVE_BASE) + "/ggml-large-v3-turbo.bin"},
        {"ggml-large-v3-turbo-q5_0.bin",547'000'000, std::string(HF_RESOLVE_BASE) + "/ggml-large-v3-turbo-q5_0.bin"},
    };
}

static size_t write_cb(void* ptr, size_t size, size_t nmemb, void* userdata) {
    return fwrite(ptr, size, nmemb, static_cast<FILE*>(userdata));
}

static int progress_cb(void* clientp, curl_off_t dltotal, curl_off_t dlnow, curl_off_t, curl_off_t) {
    if (!clientp || dltotal <= 0) return 0;
    auto fn = static_cast<std::function<void(double)>*>(clientp);
    (*fn)(static_cast<double>(dlnow) / static_cast<double>(dltotal));
    return 0;
}

bool ModelDownloader::download(const std::string& url, const std::string& dest_path,
                               std::function<void(double)> progress) {
    fs::create_directories(fs::path(dest_path).parent_path());

    std::string tmp = dest_path + ".part";
    FILE* fp = fopen(tmp.c_str(), "wb");
    if (!fp) return false;

    CURL* curl = curl_easy_init();
    if (!curl) { fclose(fp); return false; }

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, fp);

    if (progress) {
        curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, progress_cb);
        curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &progress);
        curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    }

    CURLcode res = curl_easy_perform(curl);
    curl_easy_cleanup(curl);
    fclose(fp);

    if (res != CURLE_OK) {
        fs::remove(tmp);
        return false;
    }

    std::error_code ec;
    fs::rename(tmp, dest_path, ec);
    return !ec;
}
