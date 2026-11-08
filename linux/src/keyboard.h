#pragma once

#include <string>

class Wayland;
struct zwp_virtual_keyboard_v1;

class Keyboard {
public:
    explicit Keyboard(Wayland& wayland);
    ~Keyboard();

    Keyboard(const Keyboard&) = delete;
    Keyboard& operator=(const Keyboard&) = delete;

    void type(const std::u32string& text);

private:
    Wayland& wayland_;
    zwp_virtual_keyboard_v1* keyboard_;
};
