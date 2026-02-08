#include "vad.h"
#include <algorithm>

std::vector<float> VoiceActivityDetector::process(const float* samples, size_t count, int sample_rate) {
    if (!is_enabled) return {samples, samples + count};

    active_sample_rate_ = sample_rate;
    int frame_size = sample_rate * 30 / 1000;
    std::vector<float> output;
    size_t offset = 0;

    while (offset < count) {
        size_t end = std::min(offset + static_cast<size_t>(frame_size), count);
        process_frame(samples + offset, end - offset, output);
        offset = end;
    }

    return output;
}

void VoiceActivityDetector::reset() {
    state = State::silence;
    is_speaking = false;
    pre_speech_buf_.clear();
    onset_buf_.clear();
    post_speech_buf_.clear();
    speech_sample_count_ = 0;
    silence_sample_count_ = 0;
}

void VoiceActivityDetector::process_frame(const float* frame, size_t len, std::vector<float>& output) {
    float rms = compute_rms(frame, len);

    switch (state) {
    case State::silence:
        if (rms >= speech_threshold) {
            state = State::speech_onset;
            speech_sample_count_ = static_cast<int>(len);
            onset_buf_.assign(frame, frame + len);
        } else {
            append_to_pre_speech(frame, len);
        }
        break;

    case State::speech_onset:
        if (rms >= speech_threshold) {
            speech_sample_count_ += static_cast<int>(len);
            onset_buf_.insert(onset_buf_.end(), frame, frame + len);

            if (speech_sample_count_ >= min_speech_samples()) {
                state = State::speaking;
                is_speaking = true;
                output.insert(output.end(), pre_speech_buf_.begin(), pre_speech_buf_.end());
                output.insert(output.end(), onset_buf_.begin(), onset_buf_.end());
                pre_speech_buf_.clear();
                onset_buf_.clear();
            }
        } else {
            append_to_pre_speech(onset_buf_.data(), onset_buf_.size());
            append_to_pre_speech(frame, len);
            onset_buf_.clear();
            speech_sample_count_ = 0;
            state = State::silence;
        }
        break;

    case State::speaking:
        if (rms < silence_threshold) {
            state = State::speech_offset;
            silence_sample_count_ = static_cast<int>(len);
            post_speech_buf_.assign(frame, frame + len);
        } else {
            output.insert(output.end(), frame, frame + len);
        }
        break;

    case State::speech_offset:
        if (rms < silence_threshold) {
            silence_sample_count_ += static_cast<int>(len);
            post_speech_buf_.insert(post_speech_buf_.end(), frame, frame + len);

            if (silence_sample_count_ >= min_silence_samples()) {
                size_t padding = std::min(static_cast<size_t>(post_speech_max_samples()), post_speech_buf_.size());
                output.insert(output.end(), post_speech_buf_.begin(), post_speech_buf_.begin() + padding);
                post_speech_buf_.clear();
                silence_sample_count_ = 0;
                state = State::silence;
                is_speaking = false;
                pre_speech_buf_.clear();
            }
        } else {
            output.insert(output.end(), post_speech_buf_.begin(), post_speech_buf_.end());
            output.insert(output.end(), frame, frame + len);
            post_speech_buf_.clear();
            silence_sample_count_ = 0;
            state = State::speaking;
        }
        break;
    }
}

void VoiceActivityDetector::append_to_pre_speech(const float* data, size_t len) {
    pre_speech_buf_.insert(pre_speech_buf_.end(), data, data + len);
    int max = pre_speech_max_samples();
    if (static_cast<int>(pre_speech_buf_.size()) > max) {
        pre_speech_buf_.erase(pre_speech_buf_.begin(),
                              pre_speech_buf_.begin() + (pre_speech_buf_.size() - max));
    }
}
