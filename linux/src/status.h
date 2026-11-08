#pragma once

#include <mutex>
#include <string>
#include <thread>
#include <vector>

class Status {
public:
    enum State { idle, recording, transcribing };

    Status();
    ~Status();

    Status(const Status&) = delete;
    Status& operator=(const Status&) = delete;

    void set(State state);
    void set_last(const std::string& last);

    static void follow();

private:
    int fd_;
    std::mutex mu_;
    std::vector<int> clients_;
    State state_ = idle;
    std::string last_;
    std::thread thread_;

    std::string line() const;
    void broadcast();
    void accept_loop();
};
