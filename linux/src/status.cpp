#include "status.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>

static sockaddr_un address() {
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    const char* dir = std::getenv("XDG_RUNTIME_DIR");
    if (!dir || !*dir) throw std::runtime_error("XDG_RUNTIME_DIR is not set");
    std::string path = std::string(dir) + "/speak.sock";
    std::strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
    return addr;
}

static std::string escape(const std::string& s) {
    std::string out;
    for (char c : s) {
        if (c == '\n') out += "\\n";
        else if (c == '"' || c == '\\') out += std::string("\\") + c;
        else if (static_cast<unsigned char>(c) >= 0x20) out += c;
    }
    return out;
}

Status::Status() {
    sockaddr_un addr = address();
    unlink(addr.sun_path);
    fd_ = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd_ < 0 || bind(fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0 || listen(fd_, 8) < 0)
        throw std::runtime_error(std::string("status socket: ") + strerror(errno));
    thread_ = std::thread(&Status::accept_loop, this);
}

Status::~Status() {
    shutdown(fd_, SHUT_RDWR);
    thread_.join();
    close(fd_);
    unlink(address().sun_path);
    for (int c : clients_) close(c);
}

std::string Status::line() const {
    static const char* text[] = {"stt", "● rec", "◌ stt"};
    static const char* cls[] = {"idle", "recording", "transcribing"};
    return std::string("{\"text\":\"") + text[state_] + "\",\"class\":\"" + cls[state_] + "\",\"tooltip\":\"" +
           escape(last_.empty() ? "hold PageDown to dictate" : last_) + "\"}\n";
}

void Status::broadcast() {
    std::string l = line();
    std::erase_if(clients_, [&](int c) {
        if (send(c, l.data(), l.size(), MSG_NOSIGNAL | MSG_DONTWAIT) == ssize_t(l.size())) return false;
        close(c);
        return true;
    });
}

void Status::set(State state) {
    std::lock_guard lk(mu_);
    if (state_ == state) return;
    state_ = state;
    broadcast();
}

void Status::set_last(const std::string& last) {
    std::lock_guard lk(mu_);
    last_ = last;
    broadcast();
}

void Status::accept_loop() {
    for (;;) {
        int c = accept4(fd_, nullptr, nullptr, SOCK_CLOEXEC);
        if (c < 0) return;
        std::lock_guard lk(mu_);
        std::string l = line();
        if (send(c, l.data(), l.size(), MSG_NOSIGNAL | MSG_DONTWAIT) == ssize_t(l.size())) clients_.push_back(c);
        else close(c);
    }
}

void Status::follow() {
    setvbuf(stdout, nullptr, _IOLBF, 0);
    for (;;) {
        sockaddr_un addr = address();
        int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0) {
            char buf[4096];
            ssize_t n;
            while ((n = read(fd, buf, sizeof(buf))) > 0) fwrite(buf, 1, size_t(n), stdout);
        }
        close(fd);
        printf("{\"text\":\"stt off\",\"class\":\"off\",\"tooltip\":\"speak is not running\"}\n");
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }
}
