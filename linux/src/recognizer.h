#pragma once

#include <memory>
#include <string>
#include <vector>

class Recognizer {
public:
    Recognizer(const std::string& model_dir, bool gpu);
    ~Recognizer();

    Recognizer(const Recognizer&) = delete;
    Recognizer& operator=(const Recognizer&) = delete;

    std::string transcribe(const std::vector<float>& samples) const;

private:
    struct Model;
    std::unique_ptr<Model> model_;
};
