#pragma once

#include <string>

namespace TextOutput {
    void type(const std::string& text, int delay_ms = 5);
    void paste(const std::string& text, bool restore_clipboard = true);
    void press_return();
}
