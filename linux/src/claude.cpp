#include "claude.h"

#include <nlohmann/json.hpp>

#include <glob.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <optional>
#include <set>
#include <stdexcept>
#include <string_view>

using json = nlohmann::json;

static constexpr std::string_view prefix = "\x1bP@kitty-cmd";
static constexpr std::string_view suffix = "\x1b\\";

static std::vector<std::string> sockets() {
    const char* dir = std::getenv("XDG_RUNTIME_DIR");
    if (!dir || !*dir) throw std::runtime_error("XDG_RUNTIME_DIR is not set");
    std::vector<std::string> paths;
    glob_t g;
    if (glob((std::string(dir) + "/kitty-*").c_str(), 0, nullptr, &g) == 0)
        paths.assign(g.gl_pathv, g.gl_pathv + g.gl_pathc);
    globfree(&g);
    return paths;
}

static json call(const std::string& socket, const std::string& cmd, const json& payload) {
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, socket.c_str(), sizeof(addr.sun_path) - 1);
    int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    timeval timeout{1, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    std::string request = std::string(prefix) + json{{"cmd", cmd}, {"version", {0, 41, 1}}, {"payload", payload}}.dump() + std::string(suffix);
    std::string reply;
    bool sent = connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0 &&
                write(fd, request.data(), request.size()) == ssize_t(request.size());
    char buf[65536];
    ssize_t n;
    while (sent && !reply.ends_with(suffix) && (n = read(fd, buf, sizeof(buf))) > 0) reply.append(buf, size_t(n));
    close(fd);
    if (!reply.starts_with(prefix) || !reply.ends_with(suffix)) throw std::runtime_error("kitty: no reply from " + socket);
    json r = json::parse(reply.substr(prefix.size(), reply.size() - prefix.size() - suffix.size()));
    if (!r.value("ok", false)) throw std::runtime_error("kitty: " + r.value("error", cmd + " failed"));
    return r;
}

static bool runs_claude(const json& window) {
    for (const json& p : window["foreground_processes"])
        if (!p["cmdline"].empty() && std::filesystem::path(p["cmdline"][0].get<std::string>()).filename() == "claude") return true;
    return false;
}

static std::optional<int> recent_claude(const std::string& socket) {
    std::set<int> seen;
    for (int n = 0;; ++n) {
        json r;
        try {
            r = call(socket, "ls", {{"match_tab", "recent:" + std::to_string(n)}});
        } catch (const std::runtime_error&) {
            return std::nullopt;
        }
        for (const json& os : json::parse(r["data"].get<std::string>()))
            for (const json& tab : os["tabs"]) {
                if (!seen.insert(tab["id"].get<int>()).second) return std::nullopt;
                for (const json& window : tab["windows"])
                    if (runs_claude(window)) return window["id"].get<int>();
            }
    }
}

void claude::send(const std::string& text) {
    for (const std::string& socket : sockets()) {
        std::optional<int> id = recent_claude(socket);
        if (!id) continue;
        std::string match = "id:" + std::to_string(*id);
        call(socket, "send-text", {{"match", match}, {"data", "text:" + text}, {"bracketed_paste", "enable"}});
        call(socket, "send-text", {{"match", match}, {"data", "text:\r"}});
        return;
    }
    throw std::runtime_error("no Claude Code session in kitty");
}
