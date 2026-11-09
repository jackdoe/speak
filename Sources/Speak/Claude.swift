import Foundation

enum Claude {
    static let directory = URL.homeDirectory.appending(path: "Library/Caches/kitty-speak", directoryHint: .isDirectory)

    private static let prefix = Data("\u{1b}P@kitty-cmd".utf8)
    private static let suffix = Data("\u{1b}\\".utf8)

    static func prepare() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            Log.error("kitty: \(error.localizedDescription)")
        }
    }

    static func send(_ text: String) throws {
        for socket in sockets() {
            guard let id = try recentClaude(socket) else { continue }
            let match = "id:\(id)"
            try call(socket, "send-text", ["match": match, "data": "text:" + text, "bracketed_paste": "enable"])
            try call(socket, "send-text", ["match": match, "data": "text:\r"])
            return
        }
        throw Failure("no Claude Code session in kitty")
    }

    private static func sockets() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("kitty-") }.sorted().map { directory.appending(path: $0).path }
    }

    @discardableResult
    private static func call(_ socket: String, _ command: String, _ payload: [String: String]) throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: ["cmd": command, "version": [0, 30, 0], "payload": payload] as [String: Any], options: .withoutEscapingSlashes)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { path in
            path.copyBytes(from: socket.utf8.prefix(path.count - 1))
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        let message = prefix + request + suffix
        let sent = connected && message.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == message.count

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while sent, reply.suffix(suffix.count) != suffix {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            reply.append(contentsOf: buffer[..<count])
        }
        guard reply.starts(with: prefix), reply.suffix(suffix.count) == suffix else { throw Failure("kitty: no reply from \(socket)") }
        let body = reply.dropFirst(prefix.count).dropLast(suffix.count)
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw Failure("kitty: malformed reply from \(socket)") }
        guard json["ok"] as? Bool == true else { throw Failure("kitty: " + (json["error"] as? String ?? "\(command) failed")) }
        return json
    }

    private static func recentClaude(_ socket: String) throws -> Int? {
        var seen = Set<Int>()
        var recent = 0
        while true {
            guard let reply = try? call(socket, "ls", ["match_tab": "recent:\(recent)"]) else { return nil }
            guard let data = reply["data"] as? String,
                  let osWindows = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [[String: Any]]
            else { throw Failure("kitty: malformed ls reply from \(socket)") }
            for osWindow in osWindows {
                for tab in osWindow["tabs"] as? [[String: Any]] ?? [] {
                    guard let id = tab["id"] as? Int, seen.insert(id).inserted else { return nil }
                    for window in tab["windows"] as? [[String: Any]] ?? [] where runsClaude(window) {
                        return window["id"] as? Int
                    }
                }
            }
            recent += 1
        }
    }

    private static func runsClaude(_ window: [String: Any]) -> Bool {
        let processes = window["foreground_processes"] as? [[String: Any]] ?? []
        return processes.contains { process in
            guard let command = (process["cmdline"] as? [String])?.first else { return false }
            return (command as NSString).lastPathComponent == "claude"
        }
    }
}
