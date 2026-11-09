import AVFAudio

final class Resampler {
    private static let format = AVAudioFormat(standardFormatWithSampleRate: Double(Recognizer.rate), channels: 1)!

    private let converter: AVAudioConverter
    private let output: AVAudioPCMBuffer

    init?(from input: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: Self.format),
              let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(Recognizer.rate / 4))
        else { return nil }
        self.converter = converter
        self.output = output
    }

    func convert(_ buffer: AVAudioPCMBuffer, last: Bool, _ emit: (UnsafeBufferPointer<Float>) -> Void) {
        nonisolated(unsafe) let buffer = buffer
        nonisolated(unsafe) var fed = false
        var status = AVAudioConverterOutputStatus.haveData
        while status == .haveData {
            status = converter.convert(to: output, error: nil) { _, input in
                if fed {
                    input.pointee = last ? .endOfStream : .noDataNow
                    return nil
                }
                fed = true
                input.pointee = .haveData
                return buffer
            }
            emit(UnsafeBufferPointer(start: output.floatChannelData?[0], count: Int(output.frameLength)))
        }
    }
}
