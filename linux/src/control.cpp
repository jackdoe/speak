#include "control.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cstring>
#include <cstdlib>
#include <cstdio>

std::string ControlServer::socket_path() {
    const char* runtime = std::getenv("XDG_RUNTIME_DIR");
    if (runtime && runtime[0]) return std::string(runtime) + "/speak.sock";
    return "/tmp/speak-" + std::to_string(getuid()) + ".sock";
}

ControlServer::~ControlServer() {
    stop();
}

void ControlServer::start() {
    std::string path = socket_path();
    unlink(path.c_str());

    fd_ = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd_ < 0) return;

    struct sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);

    if (bind(fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        close(fd_);
        fd_ = -1;
        return;
    }

    listen(fd_, 4);
    running_ = true;
    thread_ = std::thread(&ControlServer::accept_loop, this);
}

void ControlServer::stop() {
    running_ = false;
    if (fd_ >= 0) {
        shutdown(fd_, SHUT_RDWR);
        close(fd_);
        fd_ = -1;
    }
    if (thread_.joinable()) thread_.join();
    unlink(socket_path().c_str());
}

void ControlServer::accept_loop() {
    while (running_) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd_, &fds);
        struct timeval tv{0, 100000};
        if (select(fd_ + 1, &fds, nullptr, nullptr, &tv) <= 0) continue;

        int client = accept(fd_, nullptr, nullptr);
        if (client < 0) continue;

        char buf[4096];
        ssize_t n = read(client, buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = 0;
            while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r')) buf[--n] = 0;

            std::string response;
            if (on_command) response = on_command(buf);
            if (!response.empty()) {
                write(client, response.data(), response.size());
            }
        }
        close(client);
    }
}

std::string ControlServer::send_command(const std::string& cmd) {
    std::string path = socket_path();

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return "error: socket";

    struct sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);

    if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        close(fd);
        return "error: speak not running";
    }

    write(fd, cmd.data(), cmd.size());
    shutdown(fd, SHUT_WR);

    std::string response;
    char buf[4096];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        response.append(buf, n);
    }
    close(fd);
    return response;
}
