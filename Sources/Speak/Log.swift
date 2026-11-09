import Foundation

enum Log {
    static let isVerbose = Options.current?.verbose ?? false

    static func debug(_ message: @autoclosure () -> String) {
        if isVerbose { info(message()) }
    }

    static func error(_ message: String) {
        info("speak: " + message)
    }

    static func info(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
