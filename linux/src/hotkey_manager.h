#pragma once

#include <functional>
#include <cstdint>
#include <thread>
#include <atomic>

typedef struct _XDisplay Display;

class HotkeyManager {
public:
    ~HotkeyManager();

    std::function<void(bool is_send)> on_key_down;
    std::function<void(bool is_send)> on_key_up;

    void set_keysyms(uint32_t primary, uint32_t send);
    bool start();
    void stop();
    bool is_running() const { return running_; }

private:
    Display* display_ = nullptr;
    uint32_t primary_keysym_ = 0xFFC9;
    uint32_t send_keysym_ = 0xFFC8;
    unsigned int primary_keycode_ = 0;
    unsigned int send_keycode_ = 0;
    std::thread thread_;
    std::atomic<bool> running_{false};
    bool key_down_ = false;
    bool active_was_send_ = false;

    void event_loop();
    void grab_keys();
    void ungrab_keys();
};
