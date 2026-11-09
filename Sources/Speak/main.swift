import AppKit

guard let options = Options.current else {
    Log.info(Options.usage)
    exit(2)
}

if let file = options.file {
    exit(transcribe(file: file))
}

let app = App()
NSApplication.shared.delegate = app
NSApplication.shared.run()
