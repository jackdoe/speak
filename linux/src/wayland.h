#pragma once

#include <deque>
#include <functional>
#include <list>
#include <mutex>
#include <string>

struct wl_display;
struct wl_registry;
struct wl_seat;
struct zwp_virtual_keyboard_manager_v1;
struct hyprland_global_shortcuts_manager_v1;
struct hyprland_global_shortcut_v1;

class Wayland {
public:
    Wayland();
    ~Wayland();

    Wayland(const Wayland&) = delete;
    Wayland& operator=(const Wayland&) = delete;

    struct Shortcut {
        std::function<void(bool pressed)> handler;
        hyprland_global_shortcut_v1* proxy = nullptr;
    };

    void shortcut(const std::string& id, const std::string& description, std::function<void(bool pressed)> handler);
    void post(std::function<void()> task);
    void run(int stop_fd);
    void roundtrip();

    wl_display* display;
    wl_registry* registry = nullptr;
    wl_seat* seat = nullptr;
    zwp_virtual_keyboard_manager_v1* keyboard_manager = nullptr;
    hyprland_global_shortcuts_manager_v1* shortcuts = nullptr;

private:
    int wake_fd_;
    std::mutex mu_;
    std::deque<std::function<void()>> tasks_;
    std::list<Shortcut> shortcuts_;

    void drain();
};
