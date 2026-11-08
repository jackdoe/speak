#include "keyboard.h"
#include "wayland.h"

#include "virtual-keyboard-unstable-v1.h"
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include <sys/mman.h>
#include <unistd.h>

#include <chrono>
#include <map>
#include <stdexcept>
#include <vector>

static constexpr uint32_t first_keycode = 9;
static constexpr int flush_every = 64;

static xkb_keysym_t keysym(char32_t c) {
    if (c == U'\n') return XKB_KEY_Return;
    if (c == U'\t') return XKB_KEY_Tab;
    return xkb_utf32_to_keysym(c);
}

static std::string keymap(const std::vector<xkb_keysym_t>& syms) {
    std::string codes, symbols;
    for (size_t i = 0; i < syms.size(); ++i) {
        char name[64];
        xkb_keysym_get_name(syms[i], name, sizeof(name));
        std::string key = "<K" + std::to_string(i) + ">";
        codes += key + " = " + std::to_string(first_keycode + i) + ";\n";
        symbols += "key " + key + " {[" + name + "]};\n";
    }
    return "xkb_keymap {\n"
           "xkb_keycodes \"speak\" { minimum = 8; maximum = " + std::to_string(first_keycode + syms.size()) + ";\n" + codes + "};\n"
           "xkb_types \"speak\" { include \"complete\" };\n"
           "xkb_compatibility \"speak\" { include \"complete\" };\n"
           "xkb_symbols \"speak\" {\n" + symbols + "};\n"
           "};\n";
}

static uint32_t now_ms() {
    using namespace std::chrono;
    return uint32_t(duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count());
}

Keyboard::Keyboard(Wayland& w)
    : wayland_(w), keyboard_(zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(w.keyboard_manager, w.seat)) {}

Keyboard::~Keyboard() {
    zwp_virtual_keyboard_v1_destroy(keyboard_);
}

void Keyboard::type(const std::u32string& text) {
    std::map<xkb_keysym_t, uint32_t> index;
    std::vector<xkb_keysym_t> syms;
    std::vector<uint32_t> keys;
    for (char32_t c : text) {
        xkb_keysym_t sym = keysym(c);
        if (sym == XKB_KEY_NoSymbol) continue;
        auto [it, inserted] = index.try_emplace(sym, uint32_t(syms.size()));
        if (inserted) syms.push_back(sym);
        keys.push_back(it->second);
    }
    if (keys.empty()) return;

    std::string map = keymap(syms);
    int fd = memfd_create("speak-keymap", MFD_CLOEXEC);
    if (fd < 0 || write(fd, map.c_str(), map.size() + 1) != ssize_t(map.size() + 1))
        throw std::runtime_error("keyboard: keymap");
    zwp_virtual_keyboard_v1_keymap(keyboard_, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, uint32_t(map.size() + 1));
    close(fd);
    zwp_virtual_keyboard_v1_modifiers(keyboard_, 0, 0, 0, 0);

    for (size_t i = 0; i < keys.size(); ++i) {
        uint32_t code = first_keycode + keys[i] - 8;
        zwp_virtual_keyboard_v1_key(keyboard_, now_ms(), code, WL_KEYBOARD_KEY_STATE_PRESSED);
        zwp_virtual_keyboard_v1_key(keyboard_, now_ms(), code, WL_KEYBOARD_KEY_STATE_RELEASED);
        if ((i + 1) % flush_every == 0) wayland_.roundtrip();
    }
    wayland_.roundtrip();
}
