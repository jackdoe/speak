#pragma once

#include <cstdint>
#include <mutex>

typedef struct _XDisplay Display;

class Overlay {
public:
    enum class State { hidden, recording, transcribing };

    Overlay();
    ~Overlay();

    Overlay(const Overlay&) = delete;
    Overlay& operator=(const Overlay&) = delete;

    void set_state(State s);
    State state() const { return state_; }

private:
    Display* display_ = nullptr;
    unsigned long window_ = 0;
    State state_ = State::hidden;
    int size_ = 12;
    std::mutex mu_;
    unsigned long colors_[2]{};

    void create();
    void show(int color_idx);
    void hide();
};
