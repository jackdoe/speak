#include "hotkey_manager.h"
#include <X11/Xlib.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <cstdio>

HotkeyManager::~HotkeyManager() {
    stop();
}

void HotkeyManager::set_keysyms(uint32_t primary, uint32_t send) {
    primary_keysym_ = primary;
    send_keysym_ = send;
}

bool HotkeyManager::start() {
    if (running_) return true;

    display_ = XOpenDisplay(nullptr);
    if (!display_) {
        fprintf(stderr, "[HotkeyManager] Cannot open X display\n");
        return false;
    }

    primary_keycode_ = XKeysymToKeycode(display_, primary_keysym_);
    send_keycode_ = XKeysymToKeycode(display_, send_keysym_);

    if (!primary_keycode_) {
        fprintf(stderr, "[HotkeyManager] Cannot resolve primary keysym 0x%X\n", primary_keysym_);
        XCloseDisplay(display_);
        display_ = nullptr;
        return false;
    }

    XkbSetDetectableAutoRepeat(display_, True, nullptr);

    grab_keys();

    running_ = true;
    thread_ = std::thread(&HotkeyManager::event_loop, this);

    fprintf(stderr, "[HotkeyManager] Listening for keycodes %u (primary) and %u (send)\n",
            primary_keycode_, send_keycode_);
    return true;
}

void HotkeyManager::stop() {
    if (!running_) return;
    running_ = false;

    if (display_) {
        Display* wake = XOpenDisplay(nullptr);
        if (wake) {
            XSync(wake, False);
            XCloseDisplay(wake);
        }
    }

    if (thread_.joinable()) thread_.join();

    if (display_) {
        ungrab_keys();
        XCloseDisplay(display_);
        display_ = nullptr;
    }

    key_down_ = false;
}

void HotkeyManager::grab_keys() {
    Window root = DefaultRootWindow(display_);
    unsigned int mods[] = {0, Mod2Mask, LockMask, Mod2Mask | LockMask};

    for (unsigned int m : mods) {
        XGrabKey(display_, primary_keycode_, m, root, True, GrabModeAsync, GrabModeAsync);
        if (send_keycode_)
            XGrabKey(display_, send_keycode_, m, root, True, GrabModeAsync, GrabModeAsync);
    }
    XSync(display_, False);
}

void HotkeyManager::ungrab_keys() {
    Window root = DefaultRootWindow(display_);
    XUngrabKey(display_, primary_keycode_, AnyModifier, root);
    if (send_keycode_)
        XUngrabKey(display_, send_keycode_, AnyModifier, root);
    XSync(display_, False);
}

void HotkeyManager::event_loop() {
    XEvent ev;
    while (running_) {
        while (XPending(display_)) {
            XNextEvent(display_, &ev);

            unsigned int kc = 0;
            if (ev.type == KeyPress) kc = ev.xkey.keycode;
            else if (ev.type == KeyRelease) kc = ev.xkey.keycode;
            else continue;

            bool is_primary = (kc == primary_keycode_);
            bool is_send = (kc == send_keycode_);
            if (!is_primary && !is_send) continue;

            if (ev.type == KeyPress) {
                if (!key_down_) {
                    key_down_ = true;
                    active_was_send_ = is_send;
                    if (on_key_down) on_key_down(is_send);
                }
            } else {
                bool was_send = active_was_send_;
                key_down_ = false;
                if (on_key_up) on_key_up(was_send);
            }
        }

        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 10000;
        int fd = ConnectionNumber(display_);
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);
        select(fd + 1, &fds, nullptr, nullptr, &tv);
    }
}
