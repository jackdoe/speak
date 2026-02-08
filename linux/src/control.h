#pragma once

#include <string>
#include <functional>
#include <atomic>
#include <thread>

class ControlServer {
public:
    ~ControlServer();

    std::function<std::string(const std::string& cmd)> on_command;

    void start();
    void stop();

    static std::string socket_path();
    static std::string send_command(const std::string& cmd);

private:
    int fd_ = -1;
    std::thread thread_;
    std::atomic<bool> running_{false};

    void accept_loop();
};
