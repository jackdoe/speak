import AVFAudio

func transcribe(file path: String) -> Int32 {
    do {
        let samples = try read(path)
        let recognizer = try Recognizer()
        let start = ContinuousClock.now
        let text = try recognizer.transcribe(samples)
        let elapsed = (ContinuousClock.now - start) / .milliseconds(1)
        Log.info(String(format: "%.1fs audio in %.0f ms", Double(samples.count) / Double(Recognizer.rate), elapsed))
        print(text)
        return 0
    } catch {
        Log.error("\(error)")
        return 1
    }
}

private func read(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(filePath: path))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          let resampler = Resampler(from: file.processingFormat)
    else { throw Failure("\(path): unsupported audio format") }
    try file.read(into: buffer)
    var samples: [Float] = []
    resampler.convert(buffer, last: true) { samples.append(contentsOf: $0) }
    return samples
}
