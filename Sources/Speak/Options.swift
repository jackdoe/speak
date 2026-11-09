import Foundation

struct Options {
    var verbose = ProcessInfo.processInfo.environment["SPEAK_VERBOSE"] == "1"
    var file: String?

    static let current = Options(CommandLine.arguments.dropFirst())

    init?(_ arguments: ArraySlice<String>) {
        for argument in arguments {
            if argument == "--verbose" {
                verbose = true
            } else if !argument.hasPrefix("-"), file == nil {
                file = argument
            } else {
                return nil
            }
        }
    }

    static var usage: String {
        """
        Speak — hold-to-talk dictation for macOS

          Speak [--verbose]        run in the menu bar; --verbose logs key presses and timings, never text
          Speak FILE [--verbose]   transcribe an audio file and print the text

        Hold F12 to type, Shift+F12 to type and press Return,
        F11 to send to Claude Code in kitty. SPEAK_VERBOSE=1 is the same as --verbose.

        model: \(Recognizer.directory.path)
        """
    }
}
