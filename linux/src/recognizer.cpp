#include "recognizer.h"
#include "microphone.h"

#include <kaldi-native-fbank/csrc/online-feature.h>
#include <onnxruntime_cxx_api.h>

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <limits>
#include <stdexcept>

namespace fs = std::filesystem;

static constexpr int64_t window = 2000;
static constexpr int max_symbols_per_frame = 5;

static std::string find(const fs::path& dir, const std::string& stem) {
    for (auto& entry : fs::directory_iterator(dir)) {
        auto name = entry.path().filename().string();
        if (name.starts_with(stem + ".") && name.ends_with(".onnx")) return entry.path().string();
    }
    throw std::runtime_error("no " + stem + "*.onnx in " + dir.string());
}

static Ort::SessionOptions options(bool gpu) {
    Ort::SessionOptions o;
    o.SetIntraOpNumThreads(1);
    if (gpu) {
        OrtCUDAProviderOptionsV2* cuda = nullptr;
        Ort::ThrowOnError(Ort::GetApi().CreateCUDAProviderOptions(&cuda));
        o.AppendExecutionProvider_CUDA_V2(*cuda);
        Ort::GetApi().ReleaseCUDAProviderOptions(cuda);
    }
    return o;
}

struct Net {
    Ort::Session session;
    std::vector<std::string> inputs, outputs;
    std::vector<const char*> input_names, output_names;

    Net(Ort::Env& env, const std::string& path, bool gpu) : session(env, path.c_str(), options(gpu)) {
        Ort::AllocatorWithDefaultOptions alloc;
        for (size_t i = 0; i < session.GetInputCount(); ++i) inputs.push_back(session.GetInputNameAllocated(i, alloc).get());
        for (size_t i = 0; i < session.GetOutputCount(); ++i) outputs.push_back(session.GetOutputNameAllocated(i, alloc).get());
        for (auto& n : inputs) input_names.push_back(n.c_str());
        for (auto& n : outputs) output_names.push_back(n.c_str());
    }

    std::vector<Ort::Value> run(std::vector<Ort::Value>& values) {
        return session.Run({}, input_names.data(), values.data(), values.size(), output_names.data(), output_names.size());
    }
};

template <typename T>
static Ort::Value tensor(std::vector<T>& data, std::vector<int64_t> shape) {
    static const Ort::MemoryInfo cpu = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    return Ort::Value::CreateTensor<T>(cpu, data.data(), data.size(), shape.data(), shape.size());
}

struct Recognizer::Model {
    Ort::Env env{ORT_LOGGING_LEVEL_ERROR, "speak"};
    Net encoder, decoder, joiner;
    std::vector<std::string> tokens;
    knf::FbankOptions fbank;
    int64_t vocab, layers, hidden, features;

    Model(const fs::path& dir, bool gpu)
        : encoder(env, find(dir, "encoder"), gpu), decoder(env, find(dir, "decoder"), false), joiner(env, find(dir, "joiner"), false) {
        Ort::AllocatorWithDefaultOptions alloc;
        Ort::ModelMetadata meta = encoder.session.GetModelMetadata();
        auto read = [&](const char* key) {
            auto value = meta.LookupCustomMetadataMapAllocated(key, alloc);
            if (!value) throw std::runtime_error(std::string("model metadata lacks ") + key);
            return std::string(value.get());
        };
        if (read("normalize_type") != "per_feature") throw std::runtime_error("model needs per_feature normalization");
        vocab = std::stoll(read("vocab_size")) + 1;
        layers = std::stoll(read("pred_rnn_layers"));
        hidden = std::stoll(read("pred_hidden"));
        features = std::stoll(read("feat_dim"));

        std::ifstream in(dir / "tokens.txt");
        std::string line;
        while (std::getline(in, line)) {
            auto space = line.rfind(' ');
            size_t id = std::stoul(line.substr(space + 1));
            if (tokens.size() <= id) tokens.resize(id + 1);
            tokens[id] = line.substr(0, space);
        }
        if (int64_t(tokens.size()) != vocab) throw std::runtime_error("tokens.txt does not match model vocabulary");

        fbank.frame_opts.dither = 0;
        fbank.frame_opts.snip_edges = false;
        fbank.frame_opts.samp_freq = Microphone::rate;
        fbank.frame_opts.remove_dc_offset = false;
        fbank.mel_opts.num_bins = int32_t(features);
        fbank.mel_opts.low_freq = 0;
        fbank.mel_opts.high_freq = -400;
        fbank.mel_opts.is_librosa = true;
        fbank.use_log_floor = false;
        fbank.eps = std::numeric_limits<float>::epsilon() / 2;
    }

    std::vector<float> spectrogram(const std::vector<float>& samples, int64_t& frames) const {
        knf::OnlineFbank fb(fbank);
        fb.AcceptWaveform(float(Microphone::rate), samples.data(), int32_t(samples.size()));
        fb.InputFinished();
        frames = fb.NumFramesReady();
        int64_t padded = std::max<int64_t>(1, (frames + window - 1) / window) * window;
        std::vector<float> x(size_t(features * padded), 0.0f);
        for (int64_t c = 0; c < features; ++c) {
            double mean = 0, var = 0;
            for (int64_t t = 0; t < frames; ++t) mean += fb.GetFrame(int32_t(t))[c];
            mean /= double(frames);
            for (int64_t t = 0; t < frames; ++t) var += std::pow(fb.GetFrame(int32_t(t))[c] - mean, 2);
            float scale = float(1.0 / (std::sqrt(var / double(frames)) + 1e-5));
            for (int64_t t = 0; t < frames; ++t) x[size_t(c * padded + t)] = float(fb.GetFrame(int32_t(t))[c] - mean) * scale;
        }
        return x;
    }

    std::pair<Ort::Value, std::vector<Ort::Value>> predict(int32_t token, std::vector<Ort::Value> state) {
        std::vector<int32_t> target{token}, length{1};
        std::vector<Ort::Value> in;
        in.push_back(tensor(target, {1, 1}));
        in.push_back(tensor(length, {1}));
        for (auto& s : state) in.push_back(std::move(s));
        auto out = decoder.run(in);
        std::vector<Ort::Value> next;
        for (size_t i = 2; i < out.size(); ++i) next.push_back(std::move(out[i]));
        return {std::move(out[0]), std::move(next)};
    }

    std::string transcribe(const std::vector<float>& samples) {
        int64_t frames = 0;
        std::vector<float> x = spectrogram(samples, frames);
        if (frames == 0) return "";
        std::vector<int64_t> length{frames};
        std::vector<Ort::Value> in;
        in.push_back(tensor(x, {1, features, int64_t(x.size()) / features}));
        in.push_back(tensor(length, {1}));
        auto out = encoder.run(in);
        auto shape = out[0].GetTensorTypeAndShapeInfo().GetShape();
        int64_t dim = shape[1], stride = shape[2];
        int64_t steps = out[1].GetTensorData<int64_t>()[0];
        const float* encoded = out[0].GetTensorData<float>();

        std::vector<float> zeros(size_t(layers * hidden), 0.0f), zeros2 = zeros;
        std::vector<Ort::Value> state;
        state.push_back(tensor(zeros, {layers, 1, hidden}));
        state.push_back(tensor(zeros2, {layers, 1, hidden}));
        int32_t blank = int32_t(vocab - 1);
        auto [prediction, next] = predict(blank, std::move(state));

        std::string text;
        std::vector<float> frame(static_cast<size_t>(dim));
        int emitted = 0;
        for (int64_t t = 0, skip = 0; t < steps; t += skip) {
            for (int64_t d = 0; d < dim; ++d) frame[size_t(d)] = encoded[d * stride + t];
            std::vector<Ort::Value> j;
            j.push_back(tensor(frame, {1, dim, 1}));
            j.push_back(std::move(prediction));
            auto logits = joiner.run(j);
            prediction = std::move(j[1]);
            const float* p = logits[0].GetTensorData<float>();
            int64_t outputs = logits[0].GetTensorTypeAndShapeInfo().GetShape().back();
            int32_t token = int32_t(std::max_element(p, p + vocab) - p);
            skip = std::max_element(p + vocab, p + outputs) - (p + vocab);
            if (token != blank) {
                text += tokens[size_t(token)];
                std::tie(prediction, next) = predict(token, std::move(next));
                ++emitted;
            }
            if (skip > 0) emitted = 0;
            if (emitted >= max_symbols_per_frame || (token == blank && skip == 0)) {
                emitted = 0;
                skip = 1;
            }
        }

        static const std::string space = "\xe2\x96\x81";
        for (size_t at; (at = text.find(space)) != std::string::npos;) text.replace(at, space.size(), " ");
        auto first = text.find_first_not_of(' ');
        auto last = text.find_last_not_of(' ');
        return first == std::string::npos ? "" : text.substr(first, last - first + 1);
    }
};

Recognizer::Recognizer(const std::string& model_dir, bool gpu) : model_(std::make_unique<Model>(model_dir, gpu)) {
    transcribe(std::vector<float>(Microphone::rate, 0.0f));
}

Recognizer::~Recognizer() = default;

std::string Recognizer::transcribe(const std::vector<float>& samples) const {
    return model_->transcribe(samples);
}
