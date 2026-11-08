#include "wayland.h"

#include "hyprland-global-shortcuts-v1.h"
#include "virtual-keyboard-unstable-v1.h"
#include <wayland-client.h>

#include <poll.h>
#include <sys/eventfd.h>
#include <unistd.h>

#include <cstdint>
#include <cstring>
#include <stdexcept>

template <typename T>
static T* bind(wl_registry* registry, uint32_t name, const wl_interface* iface, uint32_t version) {
    return static_cast<T*>(wl_registry_bind(registry, name, iface, version));
}

static void on_global(void* data, wl_registry* registry, uint32_t name, const char* iface, uint32_t) {
    auto* w = static_cast<Wayland*>(data);
    if (!strcmp(iface, wl_seat_interface.name) && !w->seat)
        w->seat = bind<wl_seat>(registry, name, &wl_seat_interface, 1);
    else if (!strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name))
        w->keyboard_manager = bind<zwp_virtual_keyboard_manager_v1>(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    else if (!strcmp(iface, hyprland_global_shortcuts_manager_v1_interface.name))
        w->shortcuts = bind<hyprland_global_shortcuts_manager_v1>(registry, name, &hyprland_global_shortcuts_manager_v1_interface, 1);
}

static void on_global_remove(void*, wl_registry*, uint32_t) {}

static const wl_registry_listener registry_listener{on_global, on_global_remove};

Wayland::Wayland() : display(wl_display_connect(nullptr)) {
    if (!display) throw std::runtime_error("cannot connect to wayland display");
    registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, this);
    wl_display_roundtrip(display);

    auto require = [](const void* global, const char* name) {
        if (!global) throw std::runtime_error(std::string("compositor lacks ") + name);
    };
    require(seat, "wl_seat");
    require(keyboard_manager, "zwp_virtual_keyboard_manager_v1");
    require(shortcuts, "hyprland_global_shortcuts_manager_v1");

    wake_fd_ = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
}

Wayland::~Wayland() {
    for (auto& s : shortcuts_) hyprland_global_shortcut_v1_destroy(s.proxy);
    hyprland_global_shortcuts_manager_v1_destroy(shortcuts);
    zwp_virtual_keyboard_manager_v1_destroy(keyboard_manager);
    wl_seat_destroy(seat);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    close(wake_fd_);
}

static void on_pressed(void* data, hyprland_global_shortcut_v1*, uint32_t, uint32_t, uint32_t) {
    static_cast<Wayland::Shortcut*>(data)->handler(true);
}

static void on_released(void* data, hyprland_global_shortcut_v1*, uint32_t, uint32_t, uint32_t) {
    static_cast<Wayland::Shortcut*>(data)->handler(false);
}

static const hyprland_global_shortcut_v1_listener shortcut_listener{on_pressed, on_released};

void Wayland::shortcut(const std::string& id, const std::string& description, std::function<void(bool)> handler) {
    auto& s = shortcuts_.emplace_back(Shortcut{std::move(handler)});
    s.proxy = hyprland_global_shortcuts_manager_v1_register_shortcut(shortcuts, id.c_str(), "speak", description.c_str(), "");
    hyprland_global_shortcut_v1_add_listener(s.proxy, &shortcut_listener, &s);
}

void Wayland::post(std::function<void()> task) {
    {
        std::lock_guard lk(mu_);
        tasks_.push_back(std::move(task));
    }
    uint64_t one = 1;
    if (write(wake_fd_, &one, sizeof(one)) != sizeof(one)) throw std::runtime_error("wayland: wake");
}

void Wayland::drain() {
    uint64_t n;
    if (read(wake_fd_, &n, sizeof(n)) != sizeof(n)) return;
    std::deque<std::function<void()>> tasks;
    {
        std::lock_guard lk(mu_);
        tasks.swap(tasks_);
    }
    for (auto& t : tasks) t();
}

void Wayland::roundtrip() {
    wl_display_roundtrip(display);
}

void Wayland::run(int stop_fd) {
    pollfd fds[3] = {
        {wl_display_get_fd(display), POLLIN, 0},
        {wake_fd_, POLLIN, 0},
        {stop_fd, POLLIN, 0},
    };
    for (;;) {
        while (wl_display_prepare_read(display) != 0) wl_display_dispatch_pending(display);
        wl_display_flush(display);
        if (poll(fds, 3, -1) < 0) {
            wl_display_cancel_read(display);
            continue;
        }
        if (fds[0].revents & POLLIN) {
            if (wl_display_read_events(display) < 0) throw std::runtime_error("wayland connection lost");
        } else {
            wl_display_cancel_read(display);
        }
        if (fds[0].revents & (POLLERR | POLLHUP)) throw std::runtime_error("wayland connection lost");
        if (wl_display_dispatch_pending(display) < 0) throw std::runtime_error("wayland protocol error");
        if (fds[1].revents & POLLIN) drain();
        if (fds[2].revents & POLLIN) return;
    }
}
