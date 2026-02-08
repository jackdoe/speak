#include "text_output.h"
#include <unistd.h>
#include <sys/wait.h>

static void run(const char* const argv[]) {
    pid_t pid = fork();
    if (pid == 0) {
        execvp(argv[0], const_cast<char* const*>(argv));
        _exit(127);
    }
    if (pid > 0) waitpid(pid, nullptr, 0);
}

void TextOutput::type(const std::string& text, int delay_ms) {
    std::string delay_str = std::to_string(delay_ms);
    const char* argv[] = {"xdotool", "type", "--clearmodifiers", "--delay", delay_str.c_str(), text.c_str(), nullptr};
    run(argv);
}

void TextOutput::paste(const std::string& text, bool) {
    type(text);
}

void TextOutput::press_return() {
    usleep(50000);
    const char* argv[] = {"xdotool", "key", "Return", nullptr};
    run(argv);
}
